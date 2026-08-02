#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: orchestrator reconnect dispatch  (#38 M2 / PR-c)
# =============================================================================
# Drives _handle_msg for CONTROLLER_ADD/REMOVE/SLOT_DIED with the real
# slot_manager + a real temp state file, but every PROCESS-y side effect
# (spawn_instance, teardown_instance, _reflow_layout, proxy_*) stubbed to append
# to a record file — so there are NO real PIDs and NO kill hazard (unlike
# test_orchestrator). Verifies the flag-on slot_claim dispatch and that flag-off
# is unchanged. Run: bash tests/test_reconnect_dispatch.sh
# =============================================================================

readonly TEST_TOTAL=15

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pre-lock runtime_context constants so MCSS_CONTROLLER_PROXY stays settable
# per-test; supply the source-time constants the modules read.
export _MCSS_CONSTANTS_LOCKED=1
export MCSS_MAX_PLAYERS=4 MCSS_TEST_NOW=1000000
export MCSS_STEAM_VENDOR_ID=28de MCSS_STEAM_PRODUCT_ID=11ff
export MCSS_RAW_BINDING=1 MCSS_INSTANCE_PREFIX=latestUpdate- MCSS_ACCOUNT_PREFIX=Player
export MCSS_WINDOW_TITLE_PREFIX=SplitscreenP MCSS_STATE_LOCK_TIMEOUT_S=5
export ORCHESTRATOR_SPAWN_DELAY_S=0

for m in runtime_context controller_monitor window_manager instance_lifecycle \
         slot_manager controller_proxy orchestrator; do
    # shellcheck source=/dev/null
    source "$REPO_ROOT/modules/$m.sh"
done

TESTS_PASSED=0
TESTS_FAILED=0
STATE_DIR=""
RECORD=""
declare -a _SPAWN_PIDS=()

# --- process-y side effects stubbed (record calls; spawn no real PID) ---
spawn_instance()    { echo "spawn:$1:$2:$3" >> "$RECORD"; return 0; }
teardown_instance() { echo "teardown:$1" >> "$RECORD"; return 0; }
_reflow_layout()    { return 0; }
_collect_mask_pairs() { return 0; }
proxy_repoint_slot() { echo "repoint:$1:$2" >> "$RECORD"; return 0; }
proxy_stop_slot()    { echo "stop:$1" >> "$RECORD"; return 0; }
proxy_quiesce_slot() { echo "quiesce:$1" >> "$RECORD"; return 0; }

_slot() {
    jq -cn --argjson a "$1" --arg u "$2" --argjson d "$3" --argjson t "$4" \
        --arg ev "${5:-/dev/input/event$RANDOM}" \
        '{active:$a, phys_uniq:$u, phys_vendor:"054c", phys_product:"09cc",
          event_node:$ev, js_node:"/dev/input/js0",
          disconnected:$d, disconnected_at:(if $t<0 then null else $t end)}'
}
_seed() {
    STATE_DIR=$(mktemp -d)
    export SPLITSCREEN_STATE="$STATE_DIR/state.json"
    export MCSS_STATE_LOCK="$SPLITSCREEN_STATE.lock"
    RECORD="$STATE_DIR/record"; : > "$RECORD"
    _SPAWN_PIDS=()
    jq -n --argjson slots "$1" '{mode:"docked", slots:$slots}' > "$SPLITSCREEN_STATE"
}
_cleanup() { [[ -n "$STATE_DIR" ]] && rm -rf "$STATE_DIR"; STATE_DIR=""; }
_wait_spawns() { (( ${#_SPAWN_PIDS[@]} )) && wait "${_SPAWN_PIDS[@]}" 2>/dev/null || true; }
_rec() { cat "$RECORD" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

assert_equals() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $name — got \"$actual\""; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $name — expected \"$expected\", got \"$actual\""; TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- flag OFF: legacy path unchanged ---

test_off_spawns_and_records_no_identity() {
    export MCSS_CONTROLLER_PROXY=0
    _seed "$(jq -n '{}')"
    _handle_msg "CONTROLLER_ADD /dev/input/event5 /dev/input/js0 054c 09cc aa:bb" >/dev/null 2>&1
    _wait_spawns
    assert_equals "$(_rec)" "spawn:1:/dev/input/event5:/dev/input/js0" \
        "flag off → legacy free-slot spawn"
    assert_equals "$(_get_slot_field 1 phys_uniq null)" "null" \
        "flag off → phys_uniq NOT written (behavior-neutral)"
    _cleanup
}

# --- flag ON: slot_claim dispatch ---

test_on_spawn_unknown_records_identity() {
    export MCSS_CONTROLLER_PROXY=1
    _seed "$(jq -n '{}')"
    _handle_msg "CONTROLLER_ADD /dev/input/event5 /dev/input/js0 054c 09cc aa:bb:cc" >/dev/null 2>&1
    _wait_spawns
    assert_equals "$(_rec)" "spawn:1:/dev/input/event5:/dev/input/js0" \
        "flag on + unknown pad + free slot → SPAWN 1"
    assert_equals "$(_get_slot_field 1 phys_uniq null)" "aa:bb:cc" \
        "flag on SPAWN → identity recorded by slot_claim"
    _cleanup
}

test_on_resume_known_disconnected() {
    export MCSS_CONTROLLER_PROXY=1
    local s2; s2=$(_slot true "aa:bb:cc" true 999990 /dev/input/event7)
    _seed "$(jq -n --argjson s2 "$s2" '{"2":$s2}')"
    _handle_msg "CONTROLLER_ADD /dev/input/event9 /dev/input/js3 054c 09cc aa:bb:cc" >/dev/null 2>&1
    _wait_spawns
    assert_equals "$(_rec)" "repoint:2:/dev/input/event9" \
        "flag on + known disconnected MAC → RESUME (proxy repoint, no spawn)"
    assert_equals "$(_get_slot_field 2 disconnected false)" "false" \
        "RESUME → disconnected flag cleared"
    assert_equals "$(_get_slot_field 2 event_node null)" "/dev/input/event9" \
        "RESUME → event_node refreshed to the new node"
    _cleanup
}

test_on_reject_full_session() {
    export MCSS_CONTROLLER_PROXY=1
    local a b c d
    a=$(_slot true A false -1); b=$(_slot true B false -1)
    c=$(_slot true C false -1); d=$(_slot true D false -1)
    _seed "$(jq -n --argjson a "$a" --argjson b "$b" --argjson c "$c" --argjson d "$d" \
        '{"1":$a,"2":$b,"3":$c,"4":$d}')"
    _handle_msg "CONTROLLER_ADD /dev/input/event9 /dev/input/js3 054c 09cc zz:zz" >/dev/null 2>&1
    _wait_spawns
    assert_equals "$(_rec)" "" \
        "flag on + full + none abandoned → REJECT (no spawn, no repoint)"
    _cleanup
}

test_on_remove_marks_abandoned() {
    export MCSS_CONTROLLER_PROXY=1
    local s3; s3=$(_slot true "aa:bb" false -1 /dev/input/event7)
    _seed "$(jq -n --argjson s3 "$s3" '{"3":$s3}')"
    _handle_msg "CONTROLLER_REMOVE /dev/input/event7" >/dev/null 2>&1
    assert_equals "$(_get_slot_field 3 disconnected false)" "true" \
        "flag on CONTROLLER_REMOVE → slot marked disconnected"
    assert_equals "$(_get_slot_field 3 disconnected_at null)" "1000000" \
        "flag on CONTROLLER_REMOVE → disconnected_at stamped"
    # #151 fix: quiesce must run BEFORE the abandon-mark, closing the
    # window where this slot's evsieve would otherwise keep watching the
    # now-stale symlink.
    assert_equals "$(_rec)" "quiesce:3" \
        "flag on CONTROLLER_REMOVE → proxy_quiesce_slot called for the slot"
    _cleanup
}

test_off_remove_does_not_mark() {
    export MCSS_CONTROLLER_PROXY=0
    local s3; s3=$(_slot true "aa:bb" false -1 /dev/input/event7)
    _seed "$(jq -n --argjson s3 "$s3" '{"3":$s3}')"
    _handle_msg "CONTROLLER_REMOVE /dev/input/event7" >/dev/null 2>&1
    assert_equals "$(_get_slot_field 3 disconnected false)" "false" \
        "flag off CONTROLLER_REMOVE → unchanged (no abandoned mark)"
    assert_equals "$(_rec)" "" \
        "flag off CONTROLLER_REMOVE → proxy_quiesce_slot NOT called (behavior-neutral)"
    _cleanup
}

test_on_slot_died_stops_and_frees() {
    export MCSS_CONTROLLER_PROXY=1
    local s2; s2=$(_slot true "aa:bb" true 999990)
    _seed "$(jq -n --argjson s2 "$s2" '{"2":$s2}')"
    _handle_msg "SLOT_DIED 2" >/dev/null 2>&1
    assert_equals "$(_rec)" "stop:2 teardown:2" \
        "flag on SLOT_DIED → proxy stopped then instance torn down"
    assert_equals "$(_get_slot_field 2 active false)" "false" \
        "flag on SLOT_DIED → slot hard-freed (active=false)"
    _cleanup
}

run_all_tests() {
    echo "=== reconnect dispatch (PR-c) test suite ==="
    echo ""
    test_off_spawns_and_records_no_identity
    test_on_spawn_unknown_records_identity
    test_on_resume_known_disconnected
    test_on_reject_full_session
    test_on_remove_marks_abandoned
    test_off_remove_does_not_mark
    test_on_slot_died_stops_and_frees
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then exit 0; else exit 1; fi
}

run_all_tests
