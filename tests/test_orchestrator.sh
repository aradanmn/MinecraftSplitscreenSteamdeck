#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: orchestrator (minecraftSplitscreen.sh integration)
# =============================================================================
# Tests sourceability, watchdog integration, SLOT_DIED handling,
# handheld→docked hot-swap, cleanup, and main() guard.
# Run: bash tests/test_orchestrator.sh
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
# the invoking shell's own session. Refuse to run rather than risk it.
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
# T6.3 — docked_flow handles SLOT_DIED: marks slot inactive via teardown
# =============================================================================
test_t6_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    local fifo="$tmpdir/fifo"
    mkfifo "$fifo"
    exec 9<>"$fifo"

    local state_file="$tmpdir/splitscreen_state.json"
    # Literal PIDs below equal FIXTURE_JAVA/BWRAP_PID_1/2 above (must stay
    # in sync — the guard above checks the named constants, not this JSON).
    cat > "$state_file" <<'JSON'
{"mode":"docked","slots":{"1":{"active":true,"pid":4999911,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":4999910},"2":{"active":true,"pid":4999922,"event_node":"/dev/input/event4","js_node":"/dev/input/js1","bwrap_pid":4999920},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local sentinel="$tmpdir/teardown_slot2"

    # All mocks defined inside the subshell to avoid polluting global scope
    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        list_eligible_controllers() { true; }
        start_controller_monitor() { sleep 60 & echo $!; }
        spawn_instance() { return 0; }
        teardown_instance() {
            local slot="$1"
            if [[ "$slot" == "2" ]]; then
                touch "$sentinel"
                jq '.slots["2"] = {active:false,pid:null,event_node:null,js_node:null,bwrap_pid:null}' \
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
        _CONTROLLER_MONITOR_PID=""
        docked_flow
    ) &
    local df_pid=$!

    sleep 0.3
    echo "SLOT_DIED 2" >> "$fifo"
    sleep 0.5

    kill "$df_pid" 2>/dev/null || true
    wait "$df_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true

    if [[ -f "$sentinel" ]]; then
        _pass "T6.3 — docked_flow handles SLOT_DIED 2: teardown_instance called for slot 2"
    else
        _fail "T6.3" "teardown_instance was not called for slot 2 after SLOT_DIED 2"
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
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        docked_flow() { return 0; }
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

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        list_eligible_controllers() { echo "/dev/input/event3 /dev/input/js0 28de 11ff"; }
        spawn_instance() { return 0; }
        teardown_all_instances() { return 0; }
        restorePanels() { return 0; }
        docked_flow() { touch "$sentinel"; return 0; }
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

    # "pid" (java) is a literal equal to FIXTURE_JAVA_PID_1 (never live);
    # bwrap_pid is a real dead PID from $! so the watchdog's kill -0 finds
    # it gone. Delimiter stays unquoted only for the $dead_pid expansion.
    cat > "$state_file" <<JSON
{"mode":"docked","slots":{"1":{"active":true,"pid":4999911,"event_node":"/dev/input/event3","js_node":"/dev/input/js0","bwrap_pid":${dead_pid}},"2":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"3":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null},"4":{"active":false,"pid":null,"event_node":null,"js_node":null,"bwrap_pid":null}}}
JSON

    local teardown_sentinel="$tmpdir/teardown_slot1"

    # Run watchdog and docked_flow concurrently, both pointing at the same FIFO.
    # All mocks defined inside each subshell to avoid polluting global scope.
    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        WATCHDOG_POLL_INTERVAL_S=0.1 start_watchdog
    ) &
    local wd_pid=$!

    (
        export SPLITSCREEN_FIFO="$fifo"
        export SPLITSCREEN_STATE="$state_file"
        list_eligible_controllers() { true; }
        start_controller_monitor() { sleep 60 & echo $!; }
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
        _CONTROLLER_MONITOR_PID=""
        docked_flow
    ) &
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
    wait "$wd_pid" "$df_pid" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true

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
