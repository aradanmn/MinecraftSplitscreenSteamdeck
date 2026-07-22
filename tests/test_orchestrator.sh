#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: orchestrator (minecraftSplitscreen.sh integration)
# =============================================================================
# Tests sourceability, watchdog integration, SLOT_DIED handling, the
# docked→handheld flow-switch signal, cleanup, and main() guard.
#
# #103: rewritten against the MODULAR layout — the orchestrator's symbols live
# in modules/orchestrator.sh now, not the top-level launcher, so structural
# assertions check the LOADED definitions (declare -f / declare -p) rather than
# grepping a file path that can move again. Behavioral tests target the function
# that OWNS the behavior: SLOT_DIED / DISPLAY_MODE_CHANGE are handled by
# _handle_msg, so they are driven through _handle_msg directly (deterministic,
# no acquisition/loop/timing races); handheld_flow and the full watchdog→FIFO→
# teardown pipeline keep their end-to-end coverage.
#
# Kill-safety (#103): the suite sources the REAL modules, and teardown_instance
# does process-GROUP kills (kill -TERM/-KILL "-<pid>") on whatever PID a state
# file names. Every fixture PID is above kernel.pid_max (guard below) so a group
# kill can never resolve to a live group, AND every test that runs a real flow
# mocks teardown_instance + start_watchdog so no real reap path ever sees suite
# state. Both belts are kept.
#
# Run: bash tests/test_orchestrator.sh   (safe to run un-namespaced)
# =============================================================================

readonly TEST_TOTAL=8

# Fixture PIDs for the mock state-file JSON below. teardown_instance (in
# modules/instance_lifecycle.sh) sends process-GROUP kills — kill -TERM
# "-${bwrap_pid}", then kill -KILL "-${bwrap_pid}" — to whatever PID a
# state file names, and the real (un-mocked) watchdog can trigger extra
# teardown rounds against these same values. Every one MUST exceed
# kernel.pid_max: the kernel never assigns a real PID/PGID above that
# cap, so these fixtures can never resolve to a live process or group.
readonly FIXTURE_BWRAP_PID_1=4999910
readonly FIXTURE_JAVA_PID_1=4999911
readonly FIXTURE_BWRAP_PID_2=4999920
readonly FIXTURE_JAVA_PID_2=4999922

# Guard: an un-namespaced run with a reachable fixture PID can have its
# group kill land on a REAL process group — this has previously SIGKILLed
# the invoking shell's session. Refuse to run rather than risk it.
_pid_max=$(cat /proc/sys/kernel/pid_max)
for _fixture_pid in "$FIXTURE_BWRAP_PID_1" "$FIXTURE_JAVA_PID_1" \
    "$FIXTURE_BWRAP_PID_2" "$FIXTURE_JAVA_PID_2"; do
    if (( _fixture_pid <= _pid_max )); then
        echo "FATAL: fixture PID $_fixture_pid <= pid_max $_pid_max." >&2
        echo "teardown_instance does process-GROUP kills on the" >&2
        echo "state-file PID; a reachable fixture PID risks hitting a" >&2
        echo "REAL process group in an un-namespaced run (this has" >&2
        echo "SIGKILLed the invoking shell's session before)." >&2
        exit 1
    fi
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# _wait_bounded PID SECS — wait up to SECS for PID to exit, return its exit code.
# On timeout, SIGKILL it and return 124. A test suite must NEVER hang on a
# flow-under-test that fails to exit: this turns "hung forever" into a bounded
# FAIL. Used everywhere the suite waits on a backgrounded real flow.
_wait_bounded() {
    local pid="$1" secs="$2" i=0
    local ticks=$(( secs * 10 ))
    while (( i < ticks )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null; return $?
        fi
        sleep 0.1
        i=$(( i + 1 ))
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
}

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

# Pre-set the GUARDED orchestrator constants BEFORE sourcing (the
# _ORCHESTRATOR_CONSTANTS_LOCKED house pattern makes them overridable this way)
# so the flows use short timeouts. docked_flow's startup acquisition loop always
# burns the FULL acquire timeout with no early break, so the stock 5s would make
# every docked test slow and timing-fragile; 1s keeps them fast and deterministic.
export _ORCHESTRATOR_CONSTANTS_LOCKED=1
export ORCHESTRATOR_SPAWN_DELAY_S=0
export ORCHESTRATOR_FIFO_READ_TIMEOUT_S=1
export ORCHESTRATOR_EMPTY_EXIT_TICKS=2
export ORCHESTRATOR_CONTROLLER_ACQUIRE_TIMEOUT_S=1

source "$REPO_ROOT/minecraftSplitscreen.sh"

# Neutralize environment-touching helpers so the flow/handler LOGIC is
# deterministic in CI (no X server, no real devices). These are peripheral to
# every assertion below — the behaviors under test (SLOT_DIED→teardown,
# DISPLAY_MODE_CHANGE→return 1, watchdog→FIFO→teardown) don't depend on them.
_reflow_layout() { return 0; }
_reap_dead_slots() { return 0; }
_check_monitor_heartbeats() { return 0; }
watch_display_mode() { return 0; }
mcss_resolve_screen() { return 0; }
_collect_mask_pairs() { return 0; }
start_controller_monitor() { return 0; }

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
# T6.2 — _WATCHDOG_PID is a defined global after sourcing the orchestrator
# =============================================================================
# #103: was `grep '_WATCHDOG_PID=""' minecraftSplitscreen.sh` — the var moved to
# modules/orchestrator.sh, so grep the launcher always failed. Assert the LOADED
# symbol instead (robust to which module owns it).
test_t6_2() {
    if declare -p _WATCHDOG_PID >/dev/null 2>&1; then
        _pass "T6.2 — _WATCHDOG_PID is defined after sourcing orchestrator"
    else
        _fail "T6.2" "_WATCHDOG_PID not defined after sourcing"
    fi
}

# =============================================================================
# T6.3 — _handle_msg tears down the slot on SLOT_DIED <n>
# =============================================================================
# The SLOT_DIED behavior is OWNED by _handle_msg (modules/orchestrator.sh), so
# drive it directly — no docked_flow acquisition/loop/timing to race.
test_t6_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":${FIXTURE_JAVA_PID_1},"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":${FIXTURE_BWRAP_PID_1}},"2":{"active":true,"pid":${FIXTURE_JAVA_PID_2},"event_node":"/dev/input/event4","js_node":"/dev/input/js1","bwrap_pid":${FIXTURE_BWRAP_PID_2}},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local sentinel="$tmpdir/teardown_slot2"
    (
        export SPLITSCREEN_STATE="$state_file"
        teardown_instance() { [[ "$1" == "2" ]] && touch "$sentinel"; return 0; }
        _handle_msg "SLOT_DIED 2"
    ) >/dev/null 2>&1 &
    _wait_bounded "$!" 8 >/dev/null 2>&1 || true

    if [[ -f "$sentinel" ]]; then
        _pass "T6.3 — _handle_msg SLOT_DIED 2 tears down slot 2"
    else
        _fail "T6.3" "teardown_instance was not called for slot 2 on SLOT_DIED 2"
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

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        list_eligible_controllers() { echo "/dev/input/event3 /dev/input/js0 28de 11ff"; }
        spawn_instance() {
            # jp/bp: FIXTURE_JAVA_PID_1/FIXTURE_BWRAP_PID_1 (never a live PID).
            jq --arg slot "$1" \
                --argjson jp "$FIXTURE_JAVA_PID_1" \
                --argjson bp "$FIXTURE_BWRAP_PID_1" \
                '.slots[$slot] = {active: true, pid: $jp,
                    event_node: "/dev/input/event3",
                    js_node: "/dev/input/js0", bwrap_pid: $bp}' \
                "$state_file" > "${state_file}.tmp" &&
                mv "${state_file}.tmp" "$state_file"
            return 0
        }
        # Kill-scoping (#103): mock teardown so no real process-GROUP kill runs;
        # the mock also marks the slot inactive so handheld_flow's loop exits.
        # start_watchdog is mocked so no real watchdog reaps against fixtures.
        teardown_instance() {
            jq ".slots[\"$1\"] = {active:false,pid:null,event_node:null,js_node:null,bwrap_pid:null}" \
                "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
            return 0
        }
        start_watchdog() { return 0; }
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        docked_flow() { return 0; }
        handheld_flow
    ) >/dev/null 2>&1 &
    local hf_pid=$!

    sleep 0.3
    echo "SLOT_DIED 1" >> "$fifo"

    local exit_code
    set +e
    _wait_bounded "$hf_pid" 8   # bounded: a stuck flow FAILS, never hangs the suite
    exit_code=$?
    set -e

    exec 9>&- || true
    rm -f "$fifo"

    if (( exit_code == 0 )); then
        _pass "T6.4 — handheld_flow exits cleanly on SLOT_DIED 1"
    else
        _fail "T6.4" "expected exit 0, got $exit_code"
    fi
}

# =============================================================================
# T6.5 — _handle_msg requests handheld re-entry on DISPLAY_MODE_CHANGE handheld
# =============================================================================
# #103: the old test asserted handheld_flow calls docked_flow on
# DISPLAY_MODE_CHANGE *docked* — a path the modular orchestrator does NOT
# implement (that handler just sets mode and returns 0; the loop keeps running).
# The real, implemented flow-switch is docked→handheld: _handle_msg tears down
# every non-slot-1 instance and returns 1, the signal main() uses to re-enter
# handheld_flow. Test that contract directly.
test_t6_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local state_file="$tmpdir/state.json"
    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":${FIXTURE_JAVA_PID_1},"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":${FIXTURE_BWRAP_PID_1}},"2":{"active":true,"pid":${FIXTURE_JAVA_PID_2},"event_node":"/dev/input/event4","js_node":"/dev/input/js1","bwrap_pid":${FIXTURE_BWRAP_PID_2}},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local sentinel="$tmpdir/teardown_slot2"
    (
        export SPLITSCREEN_STATE="$state_file"
        teardown_instance() { [[ "$1" == "2" ]] && touch "$sentinel"; return 0; }
        get_active_slots() { echo "1 2"; }
        slot_is_active() { [[ "$1" == "1" ]]; }   # slot 1 survives the transition
        _handle_msg "DISPLAY_MODE_CHANGE handheld"
    ) >/dev/null 2>&1 &
    local rc=0
    _wait_bounded "$!" 8 || rc=$?   # returns the flow's exit code; 1 = handheld re-entry requested

    if (( rc == 1 )) && [[ -f "$sentinel" ]]; then
        _pass "T6.5 — _handle_msg DISPLAY_MODE_CHANGE handheld tears down non-P1 and returns 1"
    else
        _fail "T6.5" "expected return 1 + slot-2 teardown, got rc=$rc sentinel=$([[ -f "$sentinel" ]] && echo yes || echo no)"
    fi
}

# =============================================================================
# T6.6 — cleanup() kills _WATCHDOG_PID
# =============================================================================
# #103: was `awk '/^cleanup\(\)/,/^}/' minecraftSplitscreen.sh` — cleanup() moved
# to modules/orchestrator.sh. Inspect the LOADED function body instead.
test_t6_6() {
    if declare -f cleanup 2>/dev/null | grep -q '_WATCHDOG_PID'; then
        _pass "T6.6 — cleanup() references _WATCHDOG_PID (kills the watchdog)"
    else
        _fail "T6.6" "_WATCHDOG_PID not found in the loaded cleanup() definition"
    fi
}

# =============================================================================
# T6.7 — main() is defined and the launcher entry is BASH_SOURCE-guarded
# =============================================================================
# #103: was `grep '^main()' minecraftSplitscreen.sh` — main() moved to
# modules/orchestrator.sh. Assert the LOADED symbol; keep the guard check on the
# launcher (whose own prologue/dispatch is what must stay passive on source).
test_t6_7() {
    local test_failed=0

    if ! declare -f main >/dev/null 2>&1; then
        _fail "T6.7" "main() function not defined after sourcing"
        test_failed=1
    fi

    if ! grep -q 'BASH_SOURCE\[0\]' "$REPO_ROOT/minecraftSplitscreen.sh"; then
        _fail "T6.7" "BASH_SOURCE guard not found in launcher entry script"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        _pass "T6.7 — main() defined + launcher BASH_SOURCE-guarded"
    fi
}

# =============================================================================
# T6.8 — Integration: watchdog detects dead bwrap, docked_flow tears down slot
# =============================================================================
# This is the full crash recovery pipeline:
#   watchdog polls bwrap PID → bwrap gone → SLOT_DIED written to FIFO →
#   docked_flow reads SLOT_DIED → teardown_instance → state marks slot inactive
# =============================================================================
test_t6_8() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    local state_file="$tmpdir/state.json"

    # Spawn a short-lived process to get a dead PID
    sleep 0.05 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true

    # "pid" (java) is FIXTURE_JAVA_PID_1 (never live); bwrap_pid is a real dead
    # PID from $! so the watchdog's kill -0 finds it gone.
    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":${FIXTURE_JAVA_PID_1},"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":${dead_pid}},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local teardown_sentinel="$tmpdir/teardown_slot1"

    # Run watchdog and docked_flow concurrently, both pointing at the same FIFO.
    # All mocks defined inside each subshell to avoid polluting global scope.
    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        WATCHDOG_POLL_INTERVAL_S=0.1 start_watchdog
    ) >/dev/null 2>&1 &
    local wd_pid=$!

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        # docked_flow's startup acquisition needs ≥1 eligible controller or it
        # exits before the message loop — emit one (5-field docked format).
        list_eligible_controllers() { echo "/dev/input/event9 /dev/input/js9 054c 05c4 uniqT"; }
        spawn_instance() { return 0; }
        teardown_instance() {
            local s="$1"
            if [[ "$s" == "1" ]]; then
                touch "$teardown_sentinel"
                jq '.slots["1"] = {active:false,pid:null,event_node:null,js_node:null,bwrap_pid:null}' \
                    "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
            fi
        }
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        slot_is_active() {
            jq -e ".slots[\"$1\"].active == true" "$state_file" >/dev/null 2>&1
        }
        get_active_slots() {
            jq -r '[.slots | to_entries[] | select(.value.active == true) | .key] | sort | join(" ")' \
                "$state_file" 2>/dev/null || true
        }
        # Mock the watchdog docked_flow starts INTERNALLY: otherwise it spawns a
        # REAL watchdog grandchild that survives when we kill the docked_flow
        # subshell (orphaned, still holding the CI `out=$(bash …)` capture pipe →
        # $(...) hangs forever). The test runs its OWN real watchdog separately
        # (wd_pid) to drive the pipeline.
        start_watchdog() { return 0; }
        _CONTROLLER_MONITOR_PID=""
        docked_flow
    ) >/dev/null 2>&1 &
    local df_pid=$!

    # Give up to 5s for the full pipeline to fire
    local elapsed=0
    while (( elapsed < 50 )); do
        if [[ -f "$teardown_sentinel" ]]; then
            break
        fi
        sleep 0.1
        elapsed=$(( elapsed + 1 ))
    done

    kill "$wd_pid" "$df_pid" 2>/dev/null || true
    _wait_bounded "$wd_pid" 3 >/dev/null 2>&1 || true
    _wait_bounded "$df_pid" 3 >/dev/null 2>&1 || true
    exec 9>&- || true

    if [[ -f "$teardown_sentinel" ]]; then
        _pass "T6.8 — Integration: watchdog→FIFO→docked_flow→teardown pipeline works end-to-end"
    else
        _fail "T6.8" "teardown_instance for slot 1 not called within 5s (watchdog→docked_flow pipeline broken)"
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
test_t6_8
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
