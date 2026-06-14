#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: instance_lifecycle.sh
# =============================================================================
# Uses mock bwrap, mock PolyMC, and temp state files.
# No hardware, root, or Steam client required.
# Run: bash tests/test_instance_lifecycle.sh
# =============================================================================

readonly TEST_TOTAL=9

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# instance_lifecycle calls window_manager functions (compute_grid_mode, apply_layout, _kill_placeholder)
source "$REPO_ROOT/modules/window_manager.sh"
source "$REPO_ROOT/modules/instance_lifecycle.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
    echo "[PASS] $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_fail() {
    echo "[FAIL] $1 — $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# Test T4.1 — splitscreen.properties written correctly for each slot/grid combo
# =============================================================================
test_t4_1() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    INSTANCE_LIFECYCLE_LAUNCHER_DIR="$tmpdir"

    # Each test case: active_slots, then pairs of (slot, expected_mode)
    # We test each slot that's part of the active set
    local test_failed=0
    local tests_run=0

    # Helper: test one slot's properties
    _check_props() {
        local slot="$1"
        local active="$2"
        local expected="$3"

        _write_splitscreen_properties "$slot" "$active"

        local prop_file="${tmpdir}/instances/latestUpdate-${slot}/.minecraft/config/splitscreen.properties"
        local actual
        actual=$(grep '^mode=' "$prop_file" 2>/dev/null | cut -d= -f2)

        if [[ "$actual" != "$expected" ]]; then
            _fail "T4.1.$slot" "slots='$active': expected mode=$expected, got mode=$actual"
            test_failed=1
        fi
        tests_run=$((tests_run + 1))
    }

    # Case: slots="1" → grid=full
    _check_props 1 "1"    "FULLSCREEN"

    # Case: slots="1 2" → grid=half
    _check_props 1 "1 2"  "TOP"
    _check_props 2 "1 2"  "BOTTOM"

    # Case: slots="1 2 3" → grid=quad
    _check_props 1 "1 2 3" "TOP_LEFT"
    _check_props 2 "1 2 3" "TOP_RIGHT"
    _check_props 3 "1 2 3" "BOTTOM_LEFT"

    # Case: slots="1 2 3 4" → grid=quad
    _check_props 1 "1 2 3 4" "TOP_LEFT"
    _check_props 2 "1 2 3 4" "TOP_RIGHT"
    _check_props 3 "1 2 3 4" "BOTTOM_LEFT"
    _check_props 4 "1 2 3 4" "BOTTOM_RIGHT"

    # Case: slots="1 3" → grid=quad
    _check_props 1 "1 3" "TOP_LEFT"
    _check_props 3 "1 3" "BOTTOM_LEFT"

    # Case: slots="2 4" → grid=quad
    _check_props 2 "2 4" "TOP_RIGHT"
    _check_props 4 "2 4" "BOTTOM_RIGHT"

    if (( test_failed == 0 )); then
        _pass "T4.1 — splitscreen.properties: all $tests_run cases correct"
    fi
}

# =============================================================================
# Test T4.2 — state file atomic write (no .tmp left behind)
# =============================================================================
test_t4_2() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"

    # Call update_slot_state
    update_slot_state 1 '{"active": true, "pid": 999}'

    # Verify state file is valid JSON
    if jq -e '.' "$state_file" >/dev/null 2>&1; then
        # Verify no .tmp file left behind
        local tmp_count
        tmp_count=$(find "$(dirname "$state_file")" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l)
        if (( tmp_count == 0 )); then
            _pass "T4.2 — state file atomic write: valid JSON, no .tmp leftover"
        else
            _fail "T4.2" "$tmp_count .tmp file(s) left behind"
        fi
    else
        _fail "T4.2" "state file is not valid JSON"
    fi
}

# =============================================================================
# Test T4.3 — get_active_slots returns space-separated, ascending
# =============================================================================
test_t4_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"

    # Set up: slots 1 and 3 active, 2 and 4 inactive
    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":true,"pid":100,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":50},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":true,"pid":300,"event_node":"/dev/input/event5","js_node":"/dev/input/js2","bwrap_pid":150},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local result
    result=$(get_active_slots)

    if [[ "$result" == "1 3" ]]; then
        _pass "T4.3 — get_active_slots: '1 3' (space-separated, ascending)"
    else
        _fail "T4.3" "expected '1 3', got '$result'"
    fi
}

# =============================================================================
# Test T4.4 — slot_is_active exit codes
# =============================================================================
test_t4_4() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"

    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":true,"pid":100,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":50},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":true,"pid":300,"event_node":"/dev/input/event5","js_node":"/dev/input/js2","bwrap_pid":150},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local test_failed=0
    local exit_code

    set +e
    slot_is_active 1; exit_code=$?; set -e
    if (( exit_code != 0 )); then _fail "T4.4.1" "slot 1 should be active"; test_failed=1; fi

    set +e
    slot_is_active 2; exit_code=$?; set -e
    if (( exit_code != 1 )); then _fail "T4.4.2" "slot 2 should be inactive"; test_failed=1; fi

    set +e
    slot_is_active 3; exit_code=$?; set -e
    if (( exit_code != 0 )); then _fail "T4.4.3" "slot 3 should be active"; test_failed=1; fi

    set +e
    slot_is_active 4; exit_code=$?; set -e
    if (( exit_code != 1 )); then _fail "T4.4.4" "slot 4 should be inactive"; test_failed=1; fi

    if (( test_failed == 0 )); then
        _pass "T4.4 — slot_is_active: all 4 exit codes correct"
    fi
}

# =============================================================================
# Test T4.5 — teardown_instance marks slot inactive
# =============================================================================
test_t4_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"
    INSTANCE_LIFECYCLE_LAUNCHER_DIR="$tmpdir"

    # Set up: slot 2 active with non-existent PID (kill will fail gracefully)
    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"2":{"active":true,"pid":99999,"event_node":"/dev/input/event4","js_node":"/dev/input/js1","bwrap_pid":99998},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    # Tear down slot 2 (suppress stderr noise from failed kills)
    teardown_instance 2 2>/dev/null || true

    # Verify state file shows slot 2 as inactive
    local active
    active=$(jq -r '.slots["2"].active' "$state_file")
    local pid
    pid=$(jq -r '.slots["2"].pid' "$state_file")
    local bwrap_pid
    bwrap_pid=$(jq -r '.slots["2"].bwrap_pid' "$state_file")

    if [[ "$active" == "false" && "$pid" == "null" && "$bwrap_pid" == "null" ]]; then
        _pass "T4.5 — teardown_instance marks slot inactive with null pids/nodes"
    else
        _fail "T4.5" "active=$active pid=$pid bwrap_pid=$bwrap_pid (expected false/null/null)"
    fi
}

# =============================================================================
# Test T4.6 — bwrap unavailable → exit 1 with clear message
# =============================================================================
test_t4_6() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Create an empty dir with no bwrap
    local empty_dir="$tmpdir/empty"
    mkdir -p "$empty_dir"

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"
    INSTANCE_LIFECYCLE_LAUNCHER_DIR="$tmpdir"

    local stderr_output
    local exit_code

    set +e
    stderr_output=$(PATH="$empty_dir" BWRAP_CMD="nonexistent_bwrap" spawn_instance 1 /dev/input/event3 /dev/input/js0 2>&1 >/dev/null)
    exit_code=$?
    set -e

    if (( exit_code == 1 )) && echo "$stderr_output" | grep -qi "bwrap"; then
        _pass "T4.6 — bwrap unavailable: exit 1 with 'bwrap' in error message"
    else
        _fail "T4.6" "exit_code=$exit_code, stderr='$stderr_output'"
    fi
}

# =============================================================================
# Test T4.7 — spawn_instance writes correct state fields
# =============================================================================
test_t4_7() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"
    INSTANCE_LIFECYCLE_LAUNCHER_DIR="$tmpdir"

    local mock_bin="$tmpdir/mock_bin"
    mkdir -p "$mock_bin"

    # Mock bwrap: immediately exits with success (simulates short-lived process)
    cat > "$mock_bin/bwrap" <<'MOCKBWRAP'
#!/bin/bash
echo "mock bwrap: $@" >&2
exit 0
MOCKBWRAP
    chmod +x "$mock_bin/bwrap"

    # Mock pgrep: returns a fake PID
    cat > "$mock_bin/pgrep" <<'MOCKPGREP'
#!/bin/bash
echo "12345"
MOCKPGREP
    chmod +x "$mock_bin/pgrep"

    # Mock xdotool: returns a fake window ID
    cat > "$mock_bin/xdotool" <<'MOCKXDOTOOL'
#!/bin/bash
echo "99999"
MOCKXDOTOOL
    chmod +x "$mock_bin/xdotool"

    # Mock PolyMC launcher
    cat > "$tmpdir/PolyMC.AppImage" <<'MOCKPOLY'
#!/bin/bash
exit 0
MOCKPOLY
    chmod +x "$tmpdir/PolyMC.AppImage"

    # Run spawn_instance synchronously (it will exit quickly since mocks are fast)
    # Suppress stderr noise, capture the exit code
    set +e
    BWRAP_CMD="$mock_bin/bwrap" \
        LAUNCHER_EXEC="$tmpdir/PolyMC.AppImage" \
        PATH="$mock_bin:$PATH" \
        spawn_instance 2 /dev/input/event4 /dev/input/js1 >/dev/null 2>&1
    set -e

    # Check state file for slot 2
    local active event_node js_node bwrap_pid
    active=$(jq -r '.slots["2"].active' "$state_file" 2>/dev/null || echo "null")
    event_node=$(jq -r '.slots["2"].event_node' "$state_file" 2>/dev/null || echo "null")
    js_node=$(jq -r '.slots["2"].js_node' "$state_file" 2>/dev/null || echo "null")
    bwrap_pid=$(jq -r '.slots["2"].bwrap_pid' "$state_file" 2>/dev/null || echo "null")

    if [[ "$active" == "true" && "$event_node" == "/dev/input/event4" && "$js_node" == "/dev/input/js1" && "$bwrap_pid" != "null" ]]; then
        _pass "T4.7 — spawn_instance writes correct state fields"
    else
        _fail "T4.7" "active=$active event_node=$event_node js_node=$js_node bwrap_pid=$bwrap_pid"
    fi
}

# =============================================================================
# Test T4.8 — teardown_all_instances clears all slots
# =============================================================================
test_t4_8() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"
    INSTANCE_LIFECYCLE_LAUNCHER_DIR="$tmpdir"

    # All 4 slots active with non-existent PIDs
    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":true,"pid":11111,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":11110},"2":{"active":true,"pid":22222,"event_node":"/dev/input/event4","js_node":"/dev/input/js1","bwrap_pid":22220},"3":{"active":true,"pid":33333,"event_node":"/dev/input/event5","js_node":"/dev/input/js2","bwrap_pid":33330},"4":{"active":true,"pid":44444,"event_node":"/dev/input/event6","js_node":"/dev/input/js3","bwrap_pid":44440}}}
JSON

    # Tear down all
    teardown_all_instances 2>/dev/null || true

    # Verify all 4 slots are inactive
    local test_failed=0
    local slot
    for slot in 1 2 3 4; do
        local active
        active=$(jq -r ".slots[\"$slot\"].active" "$state_file")
        if [[ "$active" != "false" ]]; then
            _fail "T4.8.$slot" "slot $slot still active"
            test_failed=1
        fi
    done

    if (( test_failed == 0 )); then
        _pass "T4.8 — teardown_all_instances clears all 4 slots"
    fi
}

# =============================================================================
# Test T4.9 — _ensure_state_file resets pre-existing corrupted state
# =============================================================================
test_t4_9() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/splitscreen_state.json"
    SPLITSCREEN_STATE="$state_file"

    # Pre-create a corrupted state file (zombie PIDs, wrong active flags)
    jq -n '{
        mode: "docked",
        slots: {
            "1": {active: true, pid: 99999, event_node: "/dev/input/event99", js_node: "/dev/input/js99", bwrap_pid: 88888},
            "2": {active: false, pid: 77777, event_node: null, js_node: null, bwrap_pid: null},
            "3": {active: true, pid: 66666, event_node: "/dev/input/event66", js_node: "/dev/input/js66", bwrap_pid: 55555},
            "4": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null}
        }
    }' > "$state_file"

    # Call _ensure_state_file — should wipe and reset
    _ensure_state_file

    # Verify all slots are inactive with null PIDs
    local active_count
    active_count=$(jq '[.slots[] | select(.active == true)] | length' "$state_file")
    if (( active_count != 0 )); then
        _fail "T4.9" "expected 0 active slots, got $active_count (stale state not reset)"
        return
    fi

    # Verify all PIDs are null
    local stale_pids
    stale_pids=$(jq '[.slots[] | select(.pid != null)] | length' "$state_file")
    if (( stale_pids != 0 )); then
        _fail "T4.9" "expected 0 non-null PIDs, got $stale_pids (stale PIDs not cleared)"
        return
    fi

    # Verify mode reset to handheld
    local mode
    mode=$(jq -r '.mode' "$state_file")
    if [[ "$mode" != "handheld" ]]; then
        _fail "T4.9" "expected mode=handheld, got $mode"
        return
    fi

    _pass "T4.9 — _ensure_state_file resets pre-existing corrupted state"
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== instance_lifecycle test suite ==="
echo ""

test_t4_1
test_t4_2
test_t4_3
test_t4_4
test_t4_5
test_t4_6
test_t4_7
test_t4_8
test_t4_9

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
