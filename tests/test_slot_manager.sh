#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: slot_manager.sh  (#38 M2 / PR-a)
# =============================================================================
# Pure state+policy — no FIFO, no bwrap, no evsieve, no hardware. Every test
# seeds a temp SPLITSCREEN_STATE JSON and asserts slot_claim's outcome or a
# release/free transition. MCSS_TEST_NOW makes the grace window deterministic.
# Run: bash tests/test_slot_manager.sh
# =============================================================================

readonly TEST_TOTAL=17

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Deterministic clock + a bounded player count for the "full session" cases.
export MCSS_TEST_NOW=1000000
export MCSS_MAX_PLAYERS=4

# State I/O primitives live in instance_lifecycle; slot_manager rides them.
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/runtime_context.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/instance_lifecycle.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/modules/slot_manager.sh"

TESTS_PASSED=0
TESTS_FAILED=0
STATE_DIR=""

# _slot: emit one slot object. Args: active uniq disc disc_at [event_node].
# disc_at < 0 → JSON null (never-disconnected). event_node defaults unique.
_slot() {
    jq -cn --argjson a "$1" --arg u "$2" --argjson d "$3" \
        --argjson t "$4" --arg ev "${5:-/dev/input/event$RANDOM}" \
        '{active:$a, phys_uniq:$u, phys_vendor:"054c", phys_product:"09cc",
          event_node:$ev, js_node:"/dev/input/js0",
          disconnected:$d, disconnected_at:(if $t<0 then null else $t end)}'
}

# _seed: point SPLITSCREEN_STATE at a fresh temp file holding {mode,slots:$1}.
# Called normally (NOT in $()) so its exports reach the test's shell.
_seed() {
    STATE_DIR=$(mktemp -d)
    export SPLITSCREEN_STATE="$STATE_DIR/state.json"
    export MCSS_STATE_LOCK="$SPLITSCREEN_STATE.lock"
    jq -n --argjson slots "$1" '{mode:"docked", slots:$slots}' > "$SPLITSCREEN_STATE"
}
_cleanup() { [[ -n "$STATE_DIR" ]] && rm -rf "$STATE_DIR"; STATE_DIR=""; }

assert_equals() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $name — got \"$actual\""
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $name — expected \"$expected\", got \"$actual\""
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- slot_claim decision matrix (design §12) ---

test_resume_known_disconnected() {
    local s2; s2=$(_slot true A true 999990)
    _seed "$(jq -n --argjson s2 "$s2" '{"2":$s2}')"
    assert_equals "$(slot_claim A 054c 09cc /dev/input/event9)" "RESUME 2" \
        "known MAC, its slot disconnected → RESUME 2"
    _cleanup
}

test_reject_known_connected() {
    local s2; s2=$(_slot true A false -1)
    _seed "$(jq -n --argjson s2 "$s2" '{"2":$s2}')"
    assert_equals "$(slot_claim A 054c 09cc /dev/input/event9)" "REJECT" \
        "known MAC, slot active+connected → REJECT (dup add)"
    _cleanup
}

test_adopt_full_session() {
    # All 4 active; slot3 abandoned. Unknown pad → ADOPT 3 (only option).
    local s1 s2 s3 s4
    s1=$(_slot true A false -1); s2=$(_slot true B false -1)
    s3=$(_slot true C true 999000); s4=$(_slot true D false -1)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" --argjson c "$s3" --argjson d "$s4" \
        '{"1":$a,"2":$b,"3":$c,"4":$d}')"
    assert_equals "$(slot_claim Z 054c 09cc /dev/input/event9)" "ADOPT 3" \
        "full session + abandoned slot3 → ADOPT 3"
    _cleanup
}

test_adopt_within_grace() {
    # slot3 abandoned 10s ago (grace 180), slot4 free → ADOPT 3 (resume-first).
    local s1 s2 s3
    s1=$(_slot true A false -1); s2=$(_slot true B false -1); s3=$(_slot true C true 999990)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" --argjson c "$s3" '{"1":$a,"2":$b,"3":$c}')"
    assert_equals "$(slot_claim Z 054c 09cc /dev/input/event9)" "ADOPT 3" \
        "abandoned within grace + free slot → ADOPT 3"
    _cleanup
}

test_spawn_past_grace() {
    # slot3 abandoned 999s ago (>180), slot4 free → SPAWN (new player).
    local s1 s2 s3
    s1=$(_slot true A false -1); s2=$(_slot true B false -1); s3=$(_slot true C true 999001)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" --argjson c "$s3" '{"1":$a,"2":$b,"3":$c}')"
    assert_equals "$(slot_claim Z 054c 09cc /dev/input/event9)" "SPAWN 4" \
        "abandoned past grace + free slot → SPAWN 4"
    _cleanup
}

test_spawn_free_no_abandoned() {
    local s1; s1=$(_slot true A false -1)
    _seed "$(jq -n --argjson a "$s1" '{"1":$a}')"
    assert_equals "$(slot_claim Z 054c 09cc /dev/input/event9)" "SPAWN 2" \
        "free slot, no abandoned → SPAWN 2"
    _cleanup
}

test_reject_full_none_abandoned() {
    local s1 s2 s3 s4
    s1=$(_slot true A false -1); s2=$(_slot true B false -1)
    s3=$(_slot true C false -1); s4=$(_slot true D false -1)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" --argjson c "$s3" --argjson d "$s4" \
        '{"1":$a,"2":$b,"3":$c,"4":$d}')"
    assert_equals "$(slot_claim Z 054c 09cc /dev/input/event9)" "REJECT" \
        "full session, none abandoned → REJECT"
    _cleanup
}

test_clone_multimatch_resume() {
    # Theoretical counterfeit case: slot2 & slot3 both disconnected, both uniq=A.
    # Physically indistinguishable → claim RESUMEs one of them (defined behavior).
    local s2 s3
    s2=$(_slot true A true 999900); s3=$(_slot true A true 999950)
    _seed "$(jq -n --argjson b "$s2" --argjson c "$s3" '{"2":$b,"3":$c}')"
    local out; out=$(slot_claim A 054c 09cc /dev/input/event9)
    case "$out" in
        "RESUME 2"|"RESUME 3") assert_equals "RESUME" "RESUME" "clone multi-match → RESUME (2 or 3)";;
        *) assert_equals "$out" "RESUME <2|3>" "clone multi-match → RESUME";;
    esac
    _cleanup
}

test_empty_uniq_no_sticky_match() {
    # A pad with no uniq must NOT sticky-match a slot that also has an empty
    # phys_uniq. slot2 here is CONNECTED with uniq="" — a blank-key collision
    # would REJECT (dup) or RESUME; instead the empty pad ignores it and takes
    # the free slot. (Grace-adoption is deliberately excluded: slot2 isn't
    # disconnected, so this isolates the identity-match rule.)
    local s2; s2=$(_slot true '' false -1)
    _seed "$(jq -n --argjson b "$s2" '{"2":$b}')"
    assert_equals "$(slot_claim '' 054c 09cc /dev/input/event9)" "SPAWN 1" \
        "empty uniq → never sticky-matches → SPAWN free slot 1"
    _cleanup
}

# --- GET helpers ---

test_find_by_uniq() {
    local s1 s2
    s1=$(_slot true '' false -1); s2=$(_slot true A false -1)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" '{"1":$a,"2":$b}')"
    assert_equals "$(slot_find_by_uniq A)" "2" "find_by_uniq matches slot2"
    assert_equals "$(slot_find_by_uniq '')" "" "find_by_uniq empty arg → no match"
    _cleanup
}

test_find_free_full() {
    local s1 s2 s3 s4
    s1=$(_slot true A false -1); s2=$(_slot true B false -1)
    s3=$(_slot true C false -1); s4=$(_slot true D false -1)
    _seed "$(jq -n --argjson a "$s1" --argjson b "$s2" --argjson c "$s3" --argjson d "$s4" \
        '{"1":$a,"2":$b,"3":$c,"4":$d}')"
    assert_equals "$(slot_find_free || echo NONE)" "NONE" "find_free all-full → return 1"
    _cleanup
}

# --- RELEASE transitions ---

test_release_marks_abandoned() {
    local s2; s2=$(_slot true A false -1 /dev/input/event7)
    _seed "$(jq -n --argjson b "$s2" '{"2":$b}')"
    slot_release /dev/input/event7
    assert_equals "$(_get_slot_field 2 disconnected false)" "true" "release → disconnected=true"
    assert_equals "$(_get_slot_field 2 disconnected_at null)" "1000000" "release → disconnected_at stamped (=now)"
    _cleanup
}

test_release_by_slot_number() {
    local s3; s3=$(_slot true A false -1)
    _seed "$(jq -n --argjson c "$s3" '{"3":$c}')"
    slot_release 3
    assert_equals "$(_get_slot_field 3 disconnected false)" "true" "release by slot number works"
    _cleanup
}

test_free_clears_slot() {
    local s2; s2=$(_slot true A true 999990)
    _seed "$(jq -n --argjson b "$s2" '{"2":$b}')"
    slot_free 2
    assert_equals "$(_get_slot_field 2 active false)" "false" "free → active=false"
    assert_equals "$(_get_slot_field 2 phys_uniq null)" "null" "free → phys_uniq cleared"
    _cleanup
}

run_all_tests() {
    echo "=== slot_manager test suite ==="
    echo ""
    test_resume_known_disconnected
    test_reject_known_connected
    test_adopt_full_session
    test_adopt_within_grace
    test_spawn_past_grace
    test_spawn_free_no_abandoned
    test_reject_full_none_abandoned
    test_clone_multimatch_resume
    test_empty_uniq_no_sticky_match
    test_find_by_uniq
    test_find_free_full
    test_release_marks_abandoned
    test_release_by_slot_number
    test_free_clears_slot
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
