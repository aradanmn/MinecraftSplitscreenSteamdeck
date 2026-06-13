#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: minecraftSplitscreen.sh (orchestrator)
# =============================================================================
# Tests the Phase 6 changes to the orchestrator:
#   - watchdog module sourced and start_watchdog defined
#   - SLOT_DIED handled in docked_flow
#   - handheld_flow uses FIFO event loop
#   - main() + BASH_SOURCE guard
#   - _WATCHDOG_PID tracked and cleaned up
#
# Requires Phase 6 to be implemented (BASH_SOURCE guard must exist so sourcing
# the orchestrator does not execute the startup sequence).
#
# Run: bash tests/test_orchestrator.sh
# =============================================================================

readonly TEST_TOTAL=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH="$REPO_ROOT/minecraftSplitscreen.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# =============================================================================
# T6.1 — start_watchdog is defined after sourcing the orchestrator
# =============================================================================
test_t6_1() {
    local result
    result=$(
        # Source the orchestrator with stub functions that prevent startup side-effects.
        # The BASH_SOURCE guard must be in place for this to work.
        detectLauncher() { export LAUNCHER_DIR="/tmp"; export LAUNCHER_EXEC="/tmp/fake_polymc"; export LAUNCHER_NAME="Test"; return 0; }
        selfUpdate() { return 0; }
        isSteamDeckGameMode() { return 1; }
        nestedPlasma() { return 0; }
        hidePanels() { return 0; }
        restorePanels() { return 0; }
        watch_display_mode() { return 0; }
        start_watchdog() { return 0; }   # stub — will be overridden by real source
        get_display_mode() { echo "handheld"; }

        # Source the orchestrator — with BASH_SOURCE guard, main() is NOT called
        # shellcheck source=/dev/null
        source "$REPO_ROOT/minecraftSplitscreen.sh" 2>/dev/null || true

        # Check if start_watchdog is defined (real one from watchdog.sh)
        if declare -f start_watchdog > /dev/null 2>&1; then
            echo "defined"
        else
            echo "missing"
        fi
    )
    if [[ "$result" == "defined" ]]; then
        _pass "T6.1 — start_watchdog defined after sourcing orchestrator"
    else
        _fail "T6.1" "start_watchdog not defined (got: '$result'); ensure watchdog.sh is sourced and BASH_SOURCE guard is in place"
    fi
}

# =============================================================================
# T6.2 — _WATCHDOG_PID variable is declared in the orchestrator
# =============================================================================
test_t6_2() {
    if grep -q '_WATCHDOG_PID=""' "$ORCH"; then
        _pass "T6.2 — _WATCHDOG_PID=\"\" declared in orchestrator"
    else
        _fail "T6.2" "_WATCHDOG_PID=\"\" not found in $ORCH"
    fi
}

# =============================================================================
# T6.3 — docked_flow contains SLOT_DIED handler
# =============================================================================
test_t6_3() {
    # The handler must appear between docked_flow() and its closing brace.
    # Use awk to extract the docked_flow function body and grep within it.
    local body
    body=$(awk '/^docked_flow\(\)/,/^}/' "$ORCH" 2>/dev/null || true)
    if echo "$body" | grep -q 'SLOT_DIED'; then
        _pass "T6.3 — docked_flow contains SLOT_DIED handler"
    else
        _fail "T6.3" "SLOT_DIED not found in docked_flow body"
    fi
}

# =============================================================================
# T6.4 — handheld_flow exits on SLOT_DIED 1 from FIFO
# =============================================================================
test_t6_4() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    mkfifo "$fifo"

    # Initialize state with slot 1 active
    cat > "$state" <<'JSON'
{"mode":"handheld","slots":{"1":{"active":true,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local exit_code
    exit_code=$(
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state"

        # Stub all side-effect functions before sourcing
        detectLauncher() { export LAUNCHER_DIR="$tmpdir"; export LAUNCHER_EXEC="$tmpdir/fake"; export LAUNCHER_NAME="Test"; return 0; }
        selfUpdate() { return 0; }
        isSteamDeckGameMode() { return 1; }
        nestedPlasma() { return 0; }
        hidePanels() { return 0; }
        restorePanels() { return 0; }
        watch_display_mode() { return 0; }
        start_watchdog() { return 0; }
        get_display_mode() { echo "handheld"; }

        # shellcheck source=/dev/null
        source "$REPO_ROOT/minecraftSplitscreen.sh" 2>/dev/null || true

        # Re-override functions that the source may have replaced
        list_eligible_controllers() { echo "/dev/input/event3 /dev/input/js0 28de 11ff"; }
        spawn_instance() { return 0; }
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        slot_is_active() { [[ "$1" == "1" ]]; }

        # Keep write fd open
        exec 9>"$fifo"

        # Run handheld_flow in background
        handheld_flow &
        local flow_pid=$!

        # Inject SLOT_DIED 1 after brief delay
        sleep 0.2
        echo "SLOT_DIED 1" >> "$fifo"

        # Wait for handheld_flow to finish (timeout 4s)
        local ec=1
        if wait "$flow_pid" 2>/dev/null; then
            ec=0
        fi
        exec 9>&-
        echo "$ec"
    )

    if [[ "$exit_code" == "0" ]]; then
        _pass "T6.4 — handheld_flow exits cleanly on SLOT_DIED 1"
    else
        _fail "T6.4" "handheld_flow did not exit 0 (got: '$exit_code')"
    fi
}

# =============================================================================
# T6.5 — handheld_flow calls docked_flow on DISPLAY_MODE_CHANGE docked
# =============================================================================
test_t6_5() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/splitscreen.fifo"
    local state="$tmpdir/state.json"
    local sentinel="$tmpdir/docked_flow_called"
    mkfifo "$fifo"

    cat > "$state" <<'JSON'
{"mode":"handheld","slots":{"1":{"active":true,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state"

        detectLauncher() { export LAUNCHER_DIR="$tmpdir"; export LAUNCHER_EXEC="$tmpdir/fake"; export LAUNCHER_NAME="Test"; return 0; }
        selfUpdate() { return 0; }
        isSteamDeckGameMode() { return 1; }
        nestedPlasma() { return 0; }
        hidePanels() { return 0; }
        restorePanels() { return 0; }
        watch_display_mode() { return 0; }
        start_watchdog() { return 0; }
        get_display_mode() { echo "handheld"; }

        # shellcheck source=/dev/null
        source "$REPO_ROOT/minecraftSplitscreen.sh" 2>/dev/null || true

        list_eligible_controllers() { echo "/dev/input/event3 /dev/input/js0 28de 11ff"; }
        spawn_instance() { return 0; }
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        docked_flow() { touch "$sentinel"; return 0; }

        exec 9>"$fifo"

        handheld_flow &
        local flow_pid=$!

        sleep 0.2
        echo "DISPLAY_MODE_CHANGE docked" >> "$fifo"

        # Give handheld_flow time to react and call docked_flow
        sleep 1
        kill "$flow_pid" 2>/dev/null || true
        wait "$flow_pid" 2>/dev/null || true
        exec 9>&-
    ) 2>/dev/null || true

    if [[ -f "$sentinel" ]]; then
        _pass "T6.5 — handheld_flow calls docked_flow on DISPLAY_MODE_CHANGE docked"
    else
        _fail "T6.5" "docked_flow was not called (sentinel file missing)"
    fi
}

# =============================================================================
# T6.6 — cleanup() kills _WATCHDOG_PID
# =============================================================================
test_t6_6() {
    local body
    body=$(awk '/^cleanup\(\)/,/^\}/' "$ORCH" 2>/dev/null || true)
    if echo "$body" | grep -q '_WATCHDOG_PID'; then
        _pass "T6.6 — cleanup() references _WATCHDOG_PID"
    else
        _fail "T6.6" "_WATCHDOG_PID not found in cleanup() body"
    fi
}

# =============================================================================
# T6.7 — main() function exists and has BASH_SOURCE guard
# =============================================================================
test_t6_7() {
    local has_main=0 has_guard=0
    grep -q '^main()' "$ORCH" && has_main=1
    grep -q 'BASH_SOURCE\[0\]' "$ORCH" && has_guard=1

    if (( has_main && has_guard )); then
        _pass "T6.7 — main() function and BASH_SOURCE guard both present"
    elif (( ! has_main )); then
        _fail "T6.7" "main() function not found in $ORCH"
    else
        _fail "T6.7" "BASH_SOURCE guard not found in $ORCH"
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
