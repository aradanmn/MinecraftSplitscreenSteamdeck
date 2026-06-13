#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: orchestrator (minecraftSplitscreen.sh integration)
# =============================================================================
# Tests sourceability, watchdog integration, SLOT_DIED handling,
# handheld→docked hot-swap, cleanup, and main() guard.
# Run: bash tests/test_orchestrator.sh
# =============================================================================

readonly TEST_TOTAL=7

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Pre-define stubs so sourcing the orchestrator doesn't run anything
_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

export LAUNCHER_DIR="$_TMPDIR"
export LAUNCHER_EXEC="$_TMPDIR/dummy"
export LAUNCHER_NAME="test"
export SPLITSCREEN_FIFO="$_TMPDIR/fifo"
export SPLITSCREEN_STATE="$_TMPDIR/splitscreen_state.json"

detectLauncher() { return 0; }
selfUpdate() { return 0; }
isSteamDeckGameMode() { return 1; }
get_display_mode() { echo "handheld"; }

source "$REPO_ROOT/minecraftSplitscreen.sh"

# =============================================================================
# T6.1 — start_watchdog is defined after sourcing the orchestrator
# =============================================================================
test_t6_1() {
    if declare -f start_watchdog >/dev/null 2>&1; then
        _pass "T6.1 — start_watchdog is defined after sourcing orchestrator"
    else
        _fail "T6.1" "start_watchdog not found"
    fi
}

# =============================================================================
# T6.2 — _WATCHDOG_PID variable is declared in the orchestrator
# =============================================================================
test_t6_2() {
    if grep -q '_WATCHDOG_PID=""' "$REPO_ROOT/minecraftSplitscreen.sh"; then
        _pass "T6.2 — _WATCHDOG_PID variable declared"
    else
        _fail "T6.2" "_WATCHDOG_PID declaration not found"
    fi
}

# =============================================================================
# T6.3 — docked_flow contains a SLOT_DIED handler
# =============================================================================
test_t6_3() {
    if grep -q 'SLOT_DIED' "$REPO_ROOT/minecraftSplitscreen.sh"; then
        _pass "T6.3 — docked_flow contains SLOT_DIED handler"
    else
        _fail "T6.3" "SLOT_DIED not found in orchestrator"
    fi
}

# =============================================================================
# T6.4 — handheld_flow exits cleanly when SLOT_DIED 1 is written to FIFO
# =============================================================================
test_t6_4() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    local state_file="$tmpdir/splitscreen_state.json"

    cat > "$state_file" <<'JSON'
{"mode":"handheld","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    # Override functions for this test
    list_eligible_controllers() {
        echo "/dev/input/event3 /dev/input/js0 28de 11ff"
    }
    spawn_instance() {
        jq --arg slot "$1" '.slots[$slot] = {active: true, pid: 1, event_node: "/dev/input/event3", js_node: "/dev/input/js0", bwrap_pid: 1}' \
            "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
        return 0
    }
    teardown_all_instances() { return 0; }
    restorePanels() { return 0; }
    docked_flow() { return 0; }

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        handheld_flow
    ) &
    local hf_pid=$!

    sleep 0.3
    echo "SLOT_DIED 1" >> "$fifo"

    local exit_code
    set +e
    wait "$hf_pid" 2>/dev/null
    exit_code=$?
    set -e

    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"

    if (( exit_code == 0 )); then
        _pass "T6.4 — handheld_flow exits cleanly on SLOT_DIED 1"
    else
        _fail "T6.4" "expected exit 0, got $exit_code"
    fi
}

# =============================================================================
# T6.5 — handheld_flow calls docked_flow when DISPLAY_MODE_CHANGE docked
# =============================================================================
test_t6_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    local state_file="$tmpdir/splitscreen_state.json"
    cat > "$state_file" <<'JSON'
{"mode":"handheld","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local sentinel="$tmpdir/docked_called"

    list_eligible_controllers() { echo "/dev/input/event3 /dev/input/js0 28de 11ff"; }
    spawn_instance() { return 0; }
    teardown_all_instances() { return 0; }
    restorePanels() { return 0; }
    docked_flow() { touch "$sentinel"; return 0; }

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        handheld_flow
    ) &
    local hf_pid=$!

    sleep 0.3
    echo "DISPLAY_MODE_CHANGE docked" >> "$fifo"

    sleep 2
    kill "$hf_pid" 2>/dev/null || true
    wait "$hf_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "$fifo"

    if [[ -f "$sentinel" ]]; then
        _pass "T6.5 — handheld_flow calls docked_flow on DISPLAY_MODE_CHANGE docked"
    else
        _fail "T6.5" "docked_flow sentinel not found"
    fi
}

# =============================================================================
# T6.6 — cleanup() kills _WATCHDOG_PID
# =============================================================================
test_t6_6() {
    local orch="$REPO_ROOT/minecraftSplitscreen.sh"

    if awk '/^cleanup\(\)/,/^}/' "$orch" | grep -q '_WATCHDOG_PID'; then
        _pass "T6.6 — cleanup() kills _WATCHDOG_PID"
    else
        _fail "T6.6" "_WATCHDOG_PID not found in cleanup()"
    fi
}

# =============================================================================
# T6.7 — main() function exists and is guarded by BASH_SOURCE check
# =============================================================================
test_t6_7() {
    local orch="$REPO_ROOT/minecraftSplitscreen.sh"
    local test_failed=0

    if grep -q '^main()' "$orch"; then
        :  # ok
    else
        _fail "T6.7" "main() function not found"
        test_failed=1
    fi

    if grep -q 'BASH_SOURCE\[0\]' "$orch"; then
        :  # ok
    else
        _fail "T6.7" "BASH_SOURCE guard not found"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        _pass "T6.7 — main() exists with BASH_SOURCE guard"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== orchestrator test suite ==="
echo ""
test_t6_1
test_t6_2
test_t6_3
test_t6_4
test_t6_5
test_t6_6
test_t6_7
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
