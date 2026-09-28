#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: tests/hardware/lib/helpers.sh — hw_reap_stale_session (T1, #201)
# =============================================================================
# hw_reap_stale_session used to run four name-matched `pkill -9 -f` sweeps
# (kwin_wayland, latestUpdate, bwrap.*PolyMC, SteamLaunch.*) on every stage
# launch/stop. On SteamOS Desktop Mode or a Bazzite desktop, kwin_wayland IS the
# operator's whole session, and `-f latestUpdate` matched any `tail -f
# .../latestUpdate-1/latest.log` in another terminal (PRINCIPLES #7).
#
# The replacement, _hw_session_pids, selects by PID only: processes whose
# environ carries the run marker (SPLITSCREEN_DEBUG_LOG=), their descendants,
# and the Steam reaper identified as the UNMARKED parent of a marked launcher
# whose cmdline names our launcher. This suite builds that exact tree out of
# renamed sleeps and proves (a) the set is precisely the reaper's tree, (b)
# the harness and unrelated processes are excluded, (c) the reap kills the
# tree and nothing else, (d) no name-matched kill is left in the helper.
#
# Every process this suite starts is tracked by PID and killed by PID.
#
# Run: bash tests/test_hw_helpers_reap.sh
# =============================================================================

readonly TEST_TOTAL=6

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
readonly HELPERS="$REPO_ROOT/tests/hardware/lib/helpers.sh"

TESTS_PASSED=0
TESTS_FAILED=0
_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# The suite itself must NOT be marked, or the marker sweep would see the
# harness as part of a run tree.
unset SPLITSCREEN_DEBUG_LOG

# Keep the helper's log and workdir out of the repo tree.
TMP="$(mktemp -d)"
export MCSS_WORKDIR="$TMP/workdir"
export HW_LOG="$TMP/hw.log"
export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0
unset SPLITSCREEN_STATE   # hw_reap_stale_session must not touch a state file

# Every PID we start, for teardown by PID (PRINCIPLES #7).
declare -a TRACKED=()
_cleanup() {
    local p
    for p in "${TRACKED[@]:-}"; do
        [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null || true
    done
    rm -rf "$TMP"
}
trap _cleanup EXIT

# shellcheck source=tests/hardware/lib/helpers.sh
source "$HELPERS"

# _descendants PID: every PID under PID (one ps snapshot), plus PID itself.
_descendants() {
    local root="$1" pid ppid
    local -A kids=()
    while read -r pid ppid; do
        kids[$ppid]+="$pid "
    done < <(ps -eo pid=,ppid= 2>/dev/null)
    local -a queue=("$root") out=()
    while (( ${#queue[@]} )); do
        pid="${queue[0]}"; queue=("${queue[@]:1}")
        out+=("$pid")
        for pid in ${kids[$pid]:-}; do queue+=("$pid"); done
    done
    printf '%s\n' "${out[@]}" | sort -n
}

# --- T1.1: structural — no name-matched kill left in the helper -------------
if grep -nE '^[^#]*\b(pkill|killall)\b' "$HELPERS" >/dev/null; then
    _fail "T1.1 no pkill/killall invocation in helpers.sh" \
        "$(grep -nE '^[^#]*\b(pkill|killall)\b' "$HELPERS" | head -3 | tr '\n' ';')"
else
    _pass "T1.1 no pkill/killall invocation in helpers.sh"
fi

# --- Build the fake run tree ------------------------------------------------
# reaper (UNMARKED, argv names SteamLaunch + our launcher)
#   ├─ sleep                     (UNMARKED — an orphan the reaper adopted; the
#   │                             kwin_wayland shape: no marker, ours by ancestry)
#   └─ bash launcher (MARKED)
#        ├─ sleep                (UNMARKED — kwin_wayland under a marked wrapper)
#        └─ sleep                (MARKED)
env -u SPLITSCREEN_DEBUG_LOG bash -c '
    exec -a "reaper SteamLaunch AppId=1 -- /x/PolyMC/minecraftSplitscreen.sh launchFromPlasma" bash -c "
        env -u SPLITSCREEN_DEBUG_LOG sleep 300 &
        SPLITSCREEN_DEBUG_LOG=/tmp/x-marker.log bash -c \"env -u SPLITSCREEN_DEBUG_LOG sleep 300 & sleep 300 & wait\" &
        wait"
' &
REAPER=$!; disown "$REAPER" 2>/dev/null || true
TRACKED+=("$REAPER")

# Bystanders that must survive: an unrelated sleep, and a renamed sleep whose
# argv is exactly what the old `pkill -9 -f latestUpdate` matched.
env -u SPLITSCREEN_DEBUG_LOG sleep 300 &
UNRELATED=$!; disown "$UNRELATED" 2>/dev/null || true
TRACKED+=("$UNRELATED")
env -u SPLITSCREEN_DEBUG_LOG bash -c 'exec -a "tail -f /home/deck/.local/share/PolyMC/instances/latestUpdate-1/.minecraft/logs/latest.log" sleep 300' &
TAILER=$!; disown "$TAILER" 2>/dev/null || true
TRACKED+=("$TAILER")

sleep 1   # let the tree fork/exec settle

mapfile -t EXPECTED < <(_descendants "$REAPER")
for p in "${EXPECTED[@]}"; do TRACKED+=("$p"); done
mapfile -t GOT < <(_hw_session_pids | sort -n)

# --- T1.2: the set is exactly the reaper's tree -----------------------------
if (( ${#EXPECTED[@]} >= 5 )) && [[ "${GOT[*]}" == "${EXPECTED[*]}" ]]; then
    _pass "T1.2 _hw_session_pids == the reaper tree (${#EXPECTED[@]} pids)"
else
    _fail "T1.2 _hw_session_pids == the reaper tree" "expected [${EXPECTED[*]}] got [${GOT[*]}]"
fi

# --- T1.3: bystanders and the harness are not in the set --------------------
case " ${GOT[*]} " in
    *" $UNRELATED "*|*" $TAILER "*|*" $$ "*)
        _fail "T1.3 unrelated sleep, latestUpdate tailer and the harness excluded" "set: [${GOT[*]}]" ;;
    *)
        _pass "T1.3 unrelated sleep, latestUpdate tailer and the harness excluded" ;;
esac

# --- T1.4: the reap kills the whole tree ------------------------------------
hw_reap_stale_session >/dev/null 2>&1
sleep 0.5
left=0
for p in "${EXPECTED[@]}"; do kill -0 "$p" 2>/dev/null && left=$((left + 1)); done
if (( left == 0 )); then
    _pass "T1.4 hw_reap_stale_session reaps every pid in the tree"
else
    _fail "T1.4 hw_reap_stale_session reaps every pid in the tree" "$left still alive"
fi

# --- T1.5: the bystanders survive -------------------------------------------
if kill -0 "$UNRELATED" 2>/dev/null; then
    _pass "T1.5 unrelated process survives the reap"
else
    _fail "T1.5 unrelated process survives the reap" "pid $UNRELATED gone"
fi

# --- T1.6: the latestUpdate tailer survives (the old pkill -f killed it) -----
if kill -0 "$TAILER" 2>/dev/null; then
    _pass "T1.6 'tail -f …/latestUpdate-1/latest.log' survives the reap"
else
    _fail "T1.6 'tail -f …/latestUpdate-1/latest.log' survives the reap" "pid $TAILER gone"
fi

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
fi
exit 1
