#!/bin/bash
# shellcheck disable=SC2016
# ^ File-wide, deliberate (must precede `set` to apply file-wide, not just to
# the next statement): `_run`'s single-quoted EXPR arguments are driver-
# script SOURCE TEXT, meant to be expanded later by the CHILD bash -c, not
# now by this shell — that is the whole point of the helper (see its header
# below). Recurs at ~30 call sites; a per-site suppression would be pure
# noise for the same one reason every time.
set -uo pipefail

# =============================================================================
# Test Suite: tests/lib/uhid_rig.sh (#136 / build plan #157, PR-2)
# =============================================================================
# Covers the rig's lifecycle logic against tests/lib/fake_pad.sh — a protocol
# double that speaks uhid_pad.py's stdin/stdout contract without touching
# /dev/uhid (MCSS_RIG_PAD_CMD, the CI seam documented in uhid_rig.sh's
# header). /dev/uhid does not exist on a GitHub runner, so this is what gives
# PR-2's fd-ordering (§4.5) and PID-recycling-safe kill (§4.3) logic real CI
# coverage instead of shipping untested. Real-device behavior stays
# Deck-only, validated by tests/probe-uhid-feasibility.sh.
#
# Every case runs a small driver script in its OWN child process (never the
# real .workdir/) via `_run`, bounded by `timeout` so a hang fails the suite
# instead of wedging CI (the #80/#103 shape). `_run`'s `$( )` wraps a whole
# CHILD PROCESS (`bash -c '...'`), never a bare call to a rig COMMAND
# function (rig_init/rig_create_pad/rig_destroy_pad/rig_inject/rig_cleanup)
# in a live rig shell — that distinction is what keeps this suite itself
# compliant with uhid_rig.sh's own "never call inside $( )" rule. Test 30 is
# the sole deliberate exception: it exists SPECIFICALLY to prove that
# misusing a command function this way does not hang the capture (it can
# still orphan a pad — that part is by design, documented in uhid_rig.sh).
#
# Run: bash tests/test_uhid_rig.sh
# =============================================================================

# 30 numbered cases from work-order §7.2 (some decompose into several
# assertions each) plus 3 assertions for the §7.1 uhid_pad.py drift guard.
readonly TEST_TOTAL=93

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly LIB="$REPO_ROOT/tests/lib/uhid_rig.sh"
readonly FAKE_PAD="$REPO_ROOT/tests/lib/fake_pad.sh"
readonly PAD_PY="$REPO_ROOT/tests/lib/uhid_pad.py"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then _pass "$name"
    else _fail "$name" "expected '$expected', got '$actual'"; fi
}

SUITE_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$SUITE_TMP_ROOT"' EXIT

# _case_dir: A fresh, uniquely-named directory under the suite's own tmp
# root (never the real .workdir/) for one test case's MCSS_WORKDIR.
_case_dir() {
    local d="$SUITE_TMP_ROOT/$1"
    mkdir -p "$d"
    printf '%s\n' "$d"
}

# _run: Execute EXPR (a bash snippet, possibly multi-line) in an isolated
# CHILD process: a caller-chosen MCSS_WORKDIR, a caller-chosen rig id, and
# MCSS_RIG_PAD_CMD pointed at fake_pad.sh (the CI seam) so no case needs
# /dev/uhid. Bounded by `timeout` so a hang fails this suite instead of
# wedging CI. Safe to wrap in `$( )`: EXPR runs as a real `bash -c` child — a
# separate process with its own fd table for its whole lifetime — not as an
# in-shell command substitution around a rig COMMAND function call, so the
# §4.5 FIFO-fd hazard the rig's own header warns about does not apply to
# this wrapper.
# Inputs:
#   $1 — bash source to run, after `source "$LIB"`
#   $2 — MCSS_WORKDIR for the child
#   $3 — MCSS_RIG_ID for the child
#   $@ (4+) — extra NAME=VALUE env assignments for this one invocation
# Outputs: sets RUN_OUT (combined stdout+stderr) and RUN_RC (exit code).
RUN_OUT=""
RUN_RC=0
_run() {
    local expr="$1" workdir="$2" rig_id="$3"
    shift 3
    # env, not a bash prefix-assignment list: "$@"'s expanded words are not
    # literal source tokens, so bash would never recognize them as
    # assignments (confirmed empirically — they'd be parsed as the command).
    RUN_OUT="$(
        env "$@" MCSS_WORKDIR="$workdir" MCSS_RIG_ID="$rig_id" \
            MCSS_RIG_PAD_CMD="bash $FAKE_PAD" \
            timeout 20 bash -c "source '$LIB'; $expr" 2>&1
    )"
    RUN_RC=$?
}

# _result: Pull one "RESULT:KEY=value" line out of the last _run's RUN_OUT.
_result() {
    grep -m1 "^RESULT:${1}=" <<< "$RUN_OUT" | sed "s/^RESULT:${1}=//"
}

# =============================================================================
# Group A — pure, no processes (work-order §7.2 items 1-6)
# =============================================================================

# Item 1: rig_default_uniq 1 = aa:bb:cc:00:00:01; rig_default_uniq 4 = …:04.
test_default_uniq_values() {
    local wd; wd="$(_case_dir case01)"
    _run 'echo "RESULT:U1=$(rig_default_uniq 1)"
          echo "RESULT:U4=$(rig_default_uniq 4)"' "$wd" case1
    _expect "1.1 rig_default_uniq 1" "$(_result U1)" "aa:bb:cc:00:00:01"
    _expect "1.2 rig_default_uniq 4" "$(_result U4)" "aa:bb:cc:00:00:04"
}

# Item 2: rig_default_uniq 0 / 9 / abc / -1 -> rc 2, no stdout.
test_default_uniq_bad_index() {
    local wd; wd="$(_case_dir case02)"
    _run 'rig_default_uniq 0   >/dev/null 2>&1; echo "RESULT:R0=$?"
          rig_default_uniq 9   >/dev/null 2>&1; echo "RESULT:R9=$?"
          rig_default_uniq abc >/dev/null 2>&1; echo "RESULT:RA=$?"
          rig_default_uniq -1  >/dev/null 2>&1; echo "RESULT:RN=$?"
          out="$(rig_default_uniq 0 2>/dev/null)"
          echo "RESULT:OUT=[$out]"' "$wd" case2
    _expect "2.1 rig_default_uniq 0 -> rc 2"   "$(_result R0)" "2"
    _expect "2.2 rig_default_uniq 9 -> rc 2"   "$(_result R9)" "2"
    _expect "2.3 rig_default_uniq abc -> rc 2" "$(_result RA)" "2"
    _expect "2.4 rig_default_uniq -1 -> rc 2"  "$(_result RN)" "2"
    _expect "2.5 rig_default_uniq 0 prints nothing" "$(_result OUT)" "[]"
}

# Item 3: rig_workdir before rig_init -> rc 1; after -> the expected path.
test_workdir_before_after_init() {
    local wd expected; wd="$(_case_dir case03)"
    _run 'rig_workdir >/dev/null 2>&1; echo "RESULT:RC=$?"' "$wd" case3
    _expect "3.1 rig_workdir before rig_init -> rc 1" "$(_result RC)" "1"

    _run 'out="$(rig_workdir 2>/dev/null)"; echo "RESULT:OUT=[$out]"' \
        "$wd" case3
    _expect "3.2 rig_workdir before rig_init prints nothing" \
        "$(_result OUT)" "[]"

    _run 'rig_init >/dev/null 2>&1; echo "RESULT:WD=$(rig_workdir)"' \
        "$wd" case3
    expected="$wd/uhid-rig/case3"
    _expect "3.3 rig_workdir after rig_init" "$(_result WD)" "$expected"
}

# Item 4: rig_init honors MCSS_RIG_ID; two ids give two disjoint directories.
test_rig_init_honors_rig_id() {
    local wd d1 d2; wd="$(_case_dir case04)"
    _run 'rig_init >/dev/null 2>&1; echo "RESULT:WD=$(rig_workdir)"' \
        "$wd" alpha
    d1="$(_result WD)"
    _run 'rig_init >/dev/null 2>&1; echo "RESULT:WD=$(rig_workdir)"' \
        "$wd" beta
    d2="$(_result WD)"
    _expect "4.1 rig_init honors MCSS_RIG_ID (alpha)" "$d1" "$wd/uhid-rig/alpha"
    _expect "4.2 rig_init honors MCSS_RIG_ID (beta)"  "$d2" "$wd/uhid-rig/beta"
    if [[ "$d1" != "$d2" && -d "$d1" && -d "$d2" ]]; then
        _pass "4.3 two rig ids -> two disjoint, existing directories"
    else
        _fail "4.3 two rig ids -> two disjoint, existing directories" \
            "d1=$d1 d2=$d2"
    fi
}

# Item 5: double-sourcing the library is safe (re-source guard).
test_double_source_is_safe() {
    local wd; wd="$(_case_dir case05)"
    _run 'set -euo pipefail
          source "'"$LIB"'"
          rig_init >/dev/null
          echo "RESULT:OK=yes"
          echo "RESULT:WD=$(rig_workdir)"' "$wd" case5
    _expect "5.1 double-source under set -e: no readonly/unbound error" \
        "$(_result OK)" "yes"
    _expect "5.2 double-source still resolves rig_workdir" \
        "$(_result WD)" "$wd/uhid-rig/case5"
}

# Item 6: FIFO/pidfile/log naming is exactly pad<N>.{fifo,pid,log}.
test_pad_file_naming() {
    local wd; wd="$(_case_dir case06)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 3 >/dev/null 2>&1
          echo "RESULT:CREATE_RC=$?"
          wd="$(rig_workdir)"
          [[ -p "$wd/pad3.fifo" ]] && echo "RESULT:FIFO=yes" || echo "RESULT:FIFO=no"
          [[ -f "$wd/pad3.pid" ]]  && echo "RESULT:PIDFILE=yes" || echo "RESULT:PIDFILE=no"
          [[ -f "$wd/pad3.log" ]]  && echo "RESULT:LOGFILE=yes" || echo "RESULT:LOGFILE=no"
          rig_cleanup >/dev/null 2>&1' "$wd" case6
    _expect "6.1 rig_create_pad 3 succeeds" "$(_result CREATE_RC)" "0"
    _expect "6.2 pad3.fifo exists (named pipe)" "$(_result FIFO)" "yes"
    _expect "6.3 pad3.pid exists"             "$(_result PIDFILE)" "yes"
    _expect "6.4 pad3.log exists"             "$(_result LOGFILE)" "yes"
}

# Drift guard (§7.1): the real uhid_pad.py --help still advertises `create`
# and the flags the rig passes, so a primitive drift fails here, not on the
# Deck. Not one of the 30 numbered items — additional coverage §7.1 asks for.
test_uhid_pad_contract_drift() {
    local out rc
    out="$(python3 "$PAD_PY" --help 2>&1)"; rc=$?
    _expect "DRIFT.1 uhid_pad.py --help exits 0" "$rc" "0"
    if [[ "$out" == *"create"* ]]; then
        _pass "DRIFT.2 --help still advertises the 'create' mode"
    else
        _fail "DRIFT.2 --help still advertises the 'create' mode" \
            "not found in: $out"
    fi
    local flag
    for flag in --uniq --name --vendor --product; do
        if [[ "$out" == *"$flag"* ]]; then
            _pass "DRIFT.3 --help still advertises $flag"
        else
            _fail "DRIFT.3 --help still advertises $flag" "not found"
        fi
    done
}

# =============================================================================
# Group B — lifecycle against the fake pad (work-order §7.2 items 7-21)
# =============================================================================

# Item 7: rig_create_pad 1 -> rc 0; pad1.{pid,fifo,log} exist; the log holds
# the `created` line.
test_create_pad_basics() {
    local wd; wd="$(_case_dir case07)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          echo "RESULT:RC=$?"
          wd="$(rig_workdir)"
          [[ -f "$wd/pad1.pid" ]] && echo "RESULT:PIDFILE=yes" || echo "RESULT:PIDFILE=no"
          [[ -p "$wd/pad1.fifo" ]] && echo "RESULT:FIFO=yes" || echo "RESULT:FIFO=no"
          [[ -f "$wd/pad1.log" ]] && echo "RESULT:LOG=yes" || echo "RESULT:LOG=no"
          grep -q "^created uniq=" "$wd/pad1.log" \
              && echo "RESULT:CREATED_LINE=yes" || echo "RESULT:CREATED_LINE=no"
          rig_cleanup >/dev/null 2>&1' "$wd" case7
    _expect "7.1 rig_create_pad 1 -> rc 0"        "$(_result RC)" "0"
    _expect "7.2 pad1.pid exists"                 "$(_result PIDFILE)" "yes"
    _expect "7.3 pad1.fifo exists"                "$(_result FIFO)" "yes"
    _expect "7.4 pad1.log exists"                 "$(_result LOG)" "yes"
    _expect "7.5 pad1.log holds the created line" "$(_result CREATED_LINE)" "yes"
}

# Item 8: rig_pad_field 1 pid matches a live process; uniq matches
# rig_default_uniq 1; starttime is non-empty and numeric.
test_pad_field_values() {
    local wd; wd="$(_case_dir case08)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid="$(rig_pad_field 1 pid)"
          echo "RESULT:PID=$pid"
          echo "RESULT:UNIQ=$(rig_pad_field 1 uniq)"
          echo "RESULT:DEFAULT_UNIQ=$(rig_default_uniq 1)"
          st="$(rig_pad_field 1 starttime)"
          kill -0 "$pid" 2>/dev/null && echo "RESULT:ALIVE=yes" || echo "RESULT:ALIVE=no"
          [[ "$st" =~ ^[0-9]+$ ]] && echo "RESULT:ST_NUMERIC=yes" || echo "RESULT:ST_NUMERIC=no"
          rig_cleanup >/dev/null 2>&1' "$wd" case8
    _expect "8.1 rig_pad_field pid names a live process" "$(_result ALIVE)" "yes"
    _expect "8.2 rig_pad_field uniq matches rig_default_uniq" \
        "$(_result UNIQ)" "$(_result DEFAULT_UNIQ)"
    _expect "8.3 rig_pad_field starttime is non-empty and numeric" \
        "$(_result ST_NUMERIC)" "yes"
}

# Item 9: rig_pad_is_live 1 -> rc 0 and prints nothing to stdout.
test_pad_is_live_predicate() {
    local wd; wd="$(_case_dir case09)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          out="$(rig_pad_is_live 1)"; rc=$?
          echo "RESULT:RC=$rc"
          echo "RESULT:OUT=[$out]"
          rig_cleanup >/dev/null 2>&1' "$wd" case9
    _expect "9.1 rig_pad_is_live 1 -> rc 0" "$(_result RC)" "0"
    _expect "9.2 rig_pad_is_live 1 prints nothing" "$(_result OUT)" "[]"
}

# Item 10: rig_create_pad 1 again -> rc 2; the original pad is untouched.
test_create_pad_already_live() {
    local wd; wd="$(_case_dir case10)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid1="$(rig_pad_field 1 pid)"
          rig_create_pad 1 >/dev/null 2>&1
          echo "RESULT:RC2=$?"
          echo "RESULT:PID1=$pid1"
          echo "RESULT:PID1_AFTER=$(rig_pad_field 1 pid)"
          rig_cleanup >/dev/null 2>&1' "$wd" case10
    _expect "10.1 re-create a live index -> rc 2" "$(_result RC2)" "2"
    _expect "10.2 original pad untouched" \
        "$(_result PID1)" "$(_result PID1_AFTER)"
}

# Item 11: explicit uniq override -> rig_pad_field 2 uniq is the override.
test_create_pad_uniq_override() {
    local wd; wd="$(_case_dir case11)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 2 aa:bb:cc:00:00:09 >/dev/null 2>&1
          echo "RESULT:RC=$?"
          echo "RESULT:UNIQ=$(rig_pad_field 2 uniq)"
          rig_cleanup >/dev/null 2>&1' "$wd" case11
    _expect "11.1 rig_create_pad with explicit uniq -> rc 0" \
        "$(_result RC)" "0"
    _expect "11.2 rig_pad_field reports the override" \
        "$(_result UNIQ)" "aa:bb:cc:00:00:09"
}

# Item 12: rig_inject acked press increases the fixture's ack count by 1.
test_inject_press_acked() {
    local wd; wd="$(_case_dir case12)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          wd="$(rig_workdir)"
          before=$(grep -c "^ok press" "$wd/pad1.log")
          rig_inject 1 "press BTN_SOUTH" >/dev/null 2>&1
          echo "RESULT:RC=$?"
          after=$(grep -c "^ok press" "$wd/pad1.log")
          echo "RESULT:DELTA=$(( after - before ))"
          rig_cleanup >/dev/null 2>&1' "$wd" case12
    _expect "12.1 rig_inject press -> rc 0" "$(_result RC)" "0"
    _expect "12.2 ack count increased by exactly 1" "$(_result DELTA)" "1"
}

# Item 13: an unknown button -> rc 1 within the ack timeout; stderr carries
# the fixture's rejection text. Captured via file redirection, NOT `$( )`
# around rig_inject itself (that call must stay a plain foreground command —
# see the suite header).
test_inject_rejected_command() {
    local wd; wd="$(_case_dir case13)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          errfile="$(mktemp)"
          rig_inject 1 "press BTN_NOPE" >/dev/null 2>"$errfile"
          echo "RESULT:RC=$?"
          grep -q "bad command" "$errfile" \
              && echo "RESULT:HAS_BADCMD=yes" || echo "RESULT:HAS_BADCMD=no"
          rig_cleanup >/dev/null 2>&1' "$wd" case13
    _expect "13.1 unknown button -> rc 1" "$(_result RC)" "1"
    _expect "13.2 stderr carries the fixture's rejection text" \
        "$(_result HAS_BADCMD)" "yes"
}

# Item 14: rig_inject on an untracked index -> rc 2, nothing written.
test_inject_untracked_index() {
    local wd; wd="$(_case_dir case14)"
    _run 'rig_init >/dev/null 2>&1
          out="$(rig_inject 9 "press BTN_SOUTH" 2>/dev/null)"
          echo "RESULT:RC=$?"
          echo "RESULT:OUT=[$out]"
          rig_cleanup >/dev/null 2>&1' "$wd" case14
    _expect "14.1 rig_inject on untracked/out-of-range index -> rc 2" \
        "$(_result RC)" "2"
    _expect "14.2 rig_inject writes nothing on rejection" \
        "$(_result OUT)" "[]"
}

# Item 15: rig_inject on a pad killed out from under the rig -> rc 1, no hang
# (the outer `_run` timeout would fail this case if it hung).
test_inject_after_external_kill() {
    local wd; wd="$(_case_dir case15)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid="$(rig_pad_field 1 pid)"
          kill -KILL "$pid" 2>/dev/null
          for i in $(seq 1 50); do
              kill -0 "$pid" 2>/dev/null || break
              sleep 0.1
          done
          rig_inject 1 "press BTN_SOUTH" >/dev/null 2>&1
          echo "RESULT:RC=$?"
          rig_cleanup >/dev/null 2>&1' "$wd" case15
    _expect "15.1 inject after external kill -> rc 1, no hang" \
        "$(_result RC)" "1"
    # RUN_RC != 124 is the direct "did the outer `timeout` fire" check —
    # the actual no-hang proof, distinct from 15.1's return-code check.
    if [[ "$RUN_RC" != "124" ]]; then
        _pass "15.2 the whole case completed before the outer timeout"
    else
        _fail "15.2 the whole case completed before the outer timeout" \
            "timed out (rc 124)"
    fi
}

# Items 16/17: rig_destroy_pad 1 -> rc 0; process gone; pad1.pid/.fifo
# removed; pad1.log RETAINED. A second destroy is idempotent (rc 0).
test_destroy_pad_and_idempotency() {
    local wd; wd="$(_case_dir case16)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid="$(rig_pad_field 1 pid)"
          wd="$(rig_workdir)"
          rig_destroy_pad 1 >/dev/null 2>&1
          echo "RESULT:RC1=$?"
          kill -0 "$pid" 2>/dev/null && echo "RESULT:GONE=no" || echo "RESULT:GONE=yes"
          [[ -e "$wd/pad1.pid" ]] && echo "RESULT:PIDFILE_GONE=no" || echo "RESULT:PIDFILE_GONE=yes"
          [[ -e "$wd/pad1.fifo" ]] && echo "RESULT:FIFO_GONE=no" || echo "RESULT:FIFO_GONE=yes"
          [[ -f "$wd/pad1.log" ]] && echo "RESULT:LOG_KEPT=yes" || echo "RESULT:LOG_KEPT=no"
          rig_destroy_pad 1 >/dev/null 2>&1
          echo "RESULT:RC2=$?"' "$wd" case16
    _expect "16.1 rig_destroy_pad 1 -> rc 0"     "$(_result RC1)" "0"
    _expect "16.2 process is gone"               "$(_result GONE)" "yes"
    _expect "16.3 pad1.pid removed"              "$(_result PIDFILE_GONE)" "yes"
    _expect "16.4 pad1.fifo removed"              "$(_result FIFO_GONE)" "yes"
    _expect "16.5 pad1.log retained (evidence)"   "$(_result LOG_KEPT)" "yes"
    _expect "17.1 rig_destroy_pad 1 again -> rc 0 (idempotent)" \
        "$(_result RC2)" "0"
}

# Item 18: FAKE_PAD_IGNORE_TERM=1, and a slow exit so EOF alone can't end it
# in time -> rig_destroy_pad still returns 0, stderr names the KILL rung.
test_destroy_pad_kill_rung() {
    local wd; wd="$(_case_dir case18)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid="$(rig_pad_field 1 pid)"
          errfile="$(mktemp)"
          rig_destroy_pad 1 >/dev/null 2>"$errfile"
          echo "RESULT:RC=$?"
          grep -q "KILL" "$errfile" && echo "RESULT:NAMES_KILL=yes" || echo "RESULT:NAMES_KILL=no"
          kill -0 "$pid" 2>/dev/null && echo "RESULT:STILL_ALIVE=yes" || echo "RESULT:STILL_ALIVE=no"' \
        "$wd" case18 \
        FAKE_PAD_IGNORE_TERM=1 FAKE_PAD_SLOW_EXIT_S=30 \
        MCSS_RIG_EXIT_TIMEOUT_S=1 MCSS_RIG_KILL_GRACE_S=1
    _expect "18.1 destroy against a TERM-ignoring pad -> rc 0" \
        "$(_result RC)" "0"
    _expect "18.2 stderr names the KILL rung" "$(_result NAMES_KILL)" "yes"
    _expect "18.3 pad is actually gone after SIGKILL" \
        "$(_result STILL_ALIVE)" "no"
}

# Item 19: FAKE_PAD_NEVER_READY=1 -> rig_create_pad rc 1 within a 1s
# readiness timeout; leaves no stale pidfile and nothing tracked.
test_create_pad_never_ready() {
    local wd; wd="$(_case_dir case19)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          echo "RESULT:RC=$?"
          wd="$(rig_workdir)"
          [[ -f "$wd/pad1.pid" ]] && echo "RESULT:STALE_PIDFILE=yes" || echo "RESULT:STALE_PIDFILE=no"
          echo "RESULT:TRACKED=$(rig_list_pads | wc -l)"' \
        "$wd" case19 \
        FAKE_PAD_NEVER_READY=1 MCSS_RIG_READY_TIMEOUT_S=1
    _expect "19.1 never-ready pad -> rc 1 within the timeout" \
        "$(_result RC)" "1"
    _expect "19.2 no stale pidfile left behind" \
        "$(_result STALE_PIDFILE)" "no"
    _expect "19.3 nothing left tracked" "$(_result TRACKED)" "0"
}

# Item 20: burst-create pads 1-4 (PR-4's shape) -> all four live, distinct
# pids and uniqs, rig_list_pads = "1 2 3 4".
test_burst_create() {
    local wd; wd="$(_case_dir case20)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1; r1=$?
          rig_create_pad 2 >/dev/null 2>&1; r2=$?
          rig_create_pad 3 >/dev/null 2>&1; r3=$?
          rig_create_pad 4 >/dev/null 2>&1; r4=$?
          echo "RESULT:RCS=$r1$r2$r3$r4"
          echo "RESULT:LIST=$(rig_list_pads | tr "\n" " " | sed "s/ $//")"
          p1="$(rig_pad_field 1 pid)"; p2="$(rig_pad_field 2 pid)"
          p3="$(rig_pad_field 3 pid)"; p4="$(rig_pad_field 4 pid)"
          echo "RESULT:PIDS_UNIQUE=$(printf "%s\n%s\n%s\n%s\n" "$p1" "$p2" "$p3" "$p4" | sort -u | wc -l)"
          u1="$(rig_pad_field 1 uniq)"; u2="$(rig_pad_field 2 uniq)"
          u3="$(rig_pad_field 3 uniq)"; u4="$(rig_pad_field 4 uniq)"
          echo "RESULT:UNIQS_UNIQUE=$(printf "%s\n%s\n%s\n%s\n" "$u1" "$u2" "$u3" "$u4" | sort -u | wc -l)"
          all=1
          for p in "$p1" "$p2" "$p3" "$p4"; do kill -0 "$p" 2>/dev/null || all=0; done
          echo "RESULT:ALL_ALIVE=$all"
          rig_cleanup >/dev/null 2>&1' "$wd" case20
    _expect "20.1 four back-to-back creates all succeed" "$(_result RCS)" "0000"
    _expect "20.2 rig_list_pads = 1 2 3 4" "$(_result LIST)" "1 2 3 4"
    _expect "20.3 four distinct pids" "$(_result PIDS_UNIQUE)" "4"
    _expect "20.4 four distinct uniqs" "$(_result UNIQS_UNIQUE)" "4"
    _expect "20.5 all four alive" "$(_result ALL_ALIVE)" "1"
}

# Item 21: destroy + recreate (PR-5's shape) -> new uniq takes effect, pid
# differs from the destroyed pad's.
test_recreate_cycle() {
    local wd; wd="$(_case_dir case21)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid_before="$(rig_pad_field 1 pid)"
          rig_destroy_pad 1 >/dev/null 2>&1
          rig_create_pad 1 aa:bb:cc:00:00:0f >/dev/null 2>&1
          echo "RESULT:RC=$?"
          echo "RESULT:UNIQ_AFTER=$(rig_pad_field 1 uniq)"
          echo "RESULT:PID_BEFORE=$pid_before"
          echo "RESULT:PID_AFTER=$(rig_pad_field 1 pid)"
          rig_cleanup >/dev/null 2>&1' "$wd" case21
    _expect "21.1 recreate with swapped uniq -> rc 0" "$(_result RC)" "0"
    _expect "21.2 rig_pad_field reports the NEW uniq" \
        "$(_result UNIQ_AFTER)" "aa:bb:cc:00:00:0f"
    if [[ "$(_result PID_BEFORE)" != "$(_result PID_AFTER)" \
        && -n "$(_result PID_AFTER)" ]]; then
        _pass "21.3 recreated pad has a different pid"
    else
        _fail "21.3 recreated pad has a different pid" \
            "before=$(_result PID_BEFORE) after=$(_result PID_AFTER)"
    fi
}

# =============================================================================
# Group C — cleanup, isolation, and the fd rules (work-order §7.2 items 22-30)
# =============================================================================

# Items 22/23: rig_cleanup with 4 pads live -> all four gone, no *.fifo left,
# rc 0. A second rig_cleanup -> rc 0, no errors, no stray output.
test_cleanup_all_and_twice() {
    local wd; wd="$(_case_dir case22)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          rig_create_pad 2 >/dev/null 2>&1
          rig_create_pad 3 >/dev/null 2>&1
          rig_create_pad 4 >/dev/null 2>&1
          p1="$(rig_pad_field 1 pid)"; p2="$(rig_pad_field 2 pid)"
          p3="$(rig_pad_field 3 pid)"; p4="$(rig_pad_field 4 pid)"
          wd="$(rig_workdir)"
          rig_cleanup >/dev/null 2>&1
          echo "RESULT:RC1=$?"
          gone=1
          for p in "$p1" "$p2" "$p3" "$p4"; do
              kill -0 "$p" 2>/dev/null && gone=0
          done
          echo "RESULT:ALL_GONE=$gone"
          echo "RESULT:FIFO_COUNT=$(find "$wd" -maxdepth 1 -name "*.fifo" | wc -l)"
          out2="$(rig_cleanup 2>&1)"
          echo "RESULT:RC2=$?"
          echo "RESULT:OUT2=[$out2]"' "$wd" case22
    _expect "22.1 rig_cleanup with 4 live -> rc 0" "$(_result RC1)" "0"
    _expect "22.2 all four pads gone"              "$(_result ALL_GONE)" "1"
    _expect "22.3 no *.fifo left"                  "$(_result FIFO_COUNT)" "0"
    _expect "23.1 second rig_cleanup -> rc 0"       "$(_result RC2)" "0"
    _expect "23.2 second rig_cleanup: no stray output" \
        "$(_result OUT2)" "[]"
}

# Item 24: foreign-PID safety — a hand-written pidfile naming a process WE
# DID NOT START, with a WRONG starttime, must not get signalled by
# rig_cleanup (the PRINCIPLES #7 regression guard). This reaches into the
# library's own in-memory map directly (white-box) to simulate a stale/
# tampered record without ever routing it through rig_create_pad.
test_foreign_pid_safety() {
    local wd; wd="$(_case_dir case24)"
    _run 'rig_init >/dev/null 2>&1
          sleep 300 &
          foreign_pid=$!
          wd="$(rig_workdir)"
          _MCSS_RIG_PIDS[3]="$foreign_pid"
          {
              echo "pid=$foreign_pid"
              echo "uniq=aa:bb:cc:00:00:99"
              echo "name=foreign"
              echo "product=0x0099"
              echo "started=0"
              echo "starttime=999999999"
              echo "fifo=$wd/pad3.fifo"
              echo "log=$wd/pad3.log"
          } > "$wd/pad3.pid"
          rig_cleanup >/dev/null 2>&1
          echo "RESULT:RC=$?"
          sleep 0.3
          kill -0 "$foreign_pid" 2>/dev/null && echo "RESULT:FOREIGN_ALIVE=yes" || echo "RESULT:FOREIGN_ALIVE=no"
          kill -KILL "$foreign_pid" 2>/dev/null || true' "$wd" case24
    _expect "24.1 rig_cleanup with a foreign/mismatched pidfile -> rc 0" \
        "$(_result RC)" "0"
    _expect "24.2 the foreign process is NOT signalled" \
        "$(_result FOREIGN_ALIVE)" "yes"
}

# Item 25: cross-rig isolation — rig_cleanup on rig A must never reach rig
# B's directory. B is set up WITHOUT going through rig_init/rig_create_pad
# (which would wipe A's in-memory tracking) — it's a hand-launched fake pad
# under a sibling uhid-rig/<id>/ directory with an accurate pidfile, playing
# the part of "some other already-running rig instance."
test_cross_rig_isolation() {
    local wd; wd="$(_case_dir case25)"
    _run 'rig_init A >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          wd_a="$(rig_workdir)"
          wd_b="$(dirname "$wd_a")/B"
          mkdir -p "$wd_b"
          fifo_b="$wd_b/pad1.fifo"
          log_b="$wd_b/pad1.log"
          mkfifo "$fifo_b"
          : > "$log_b"
          ( bash "'"$FAKE_PAD"'" create --uniq aa:bb:cc:00:00:55 \
                --name "Foreign B" --vendor 0x054c --product 0x0001
          ) < "$fifo_b" > "$log_b" 2>&1 &
          b_pid=$!
          exec {bfd}> "$fifo_b"
          for i in $(seq 1 50); do
              grep -q "^created uniq=" "$log_b" 2>/dev/null && break
              sleep 0.1
          done
          b_starttime="$(_rig_proc_starttime "$b_pid")"
          {
              echo "pid=$b_pid"
              echo "uniq=aa:bb:cc:00:00:55"
              echo "name=Foreign B"
              echo "product=0x0001"
              echo "started=0"
              echo "starttime=$b_starttime"
              echo "fifo=$fifo_b"
              echo "log=$log_b"
          } > "$wd_b/pad1.pid"

          a_pid="$(rig_pad_field 1 pid)"
          rig_cleanup >/dev/null 2>&1
          echo "RESULT:RC=$?"
          sleep 0.2
          kill -0 "$a_pid" 2>/dev/null && echo "RESULT:A_ALIVE=yes" || echo "RESULT:A_ALIVE=no"
          kill -0 "$b_pid" 2>/dev/null && echo "RESULT:B_ALIVE=yes" || echo "RESULT:B_ALIVE=no"
          [[ -f "$wd_b/pad1.pid" ]] && echo "RESULT:B_PIDFILE=yes" || echo "RESULT:B_PIDFILE=no"

          { echo destroy >&"$bfd"; } 2>/dev/null || true
          { exec {bfd}>&-; } 2>/dev/null || true
          kill -0 "$b_pid" 2>/dev/null && kill -KILL "$b_pid" 2>/dev/null || true' \
        "$wd" case25
    _expect "25.1 rig_cleanup (rig A) -> rc 0" "$(_result RC)" "0"
    _expect "25.2 rig A's own pad is gone"     "$(_result A_ALIVE)" "no"
    _expect "25.3 rig B's pad is untouched (still running)" \
        "$(_result B_ALIVE)" "yes"
    _expect "25.4 rig B's pidfile is untouched" \
        "$(_result B_PIDFILE)" "yes"
}

# Item 26: EOF teardown (Rule 1, §4.5) — closing ONLY the held write fd (no
# `destroy` line ever sent, no signal ever sent) must end the pad within the
# exit timeout. Reaches into _MCSS_RIG_FDS directly (white-box) since there
# is no public function that closes a single fd without the full escalation
# ladder.
test_eof_teardown_rule1() {
    local wd; wd="$(_case_dir case26)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          pid="$(rig_pad_field 1 pid)"
          wd="$(rig_workdir)"
          fd="${_MCSS_RIG_FDS[1]}"
          { exec {fd}>&-; } 2>/dev/null || true
          gone=0
          for i in $(seq 1 80); do
              kill -0 "$pid" 2>/dev/null || { gone=1; break; }
              sleep 0.1
          done
          echo "RESULT:EXITED=$gone"
          grep -q "destroy" "$wd/pad1.log" 2>/dev/null \
              && echo "RESULT:HAS_DESTROY=yes" || echo "RESULT:HAS_DESTROY=no"' \
        "$wd" case26
    _expect "26.1 closing only the write fd ends the pad" \
        "$(_result EXITED)" "1"
    _expect "26.2 no destroy line was ever sent" \
        "$(_result HAS_DESTROY)" "no"
}

# Item 27: cross-pad fd leak (Rule 2, §4.5) — pad 2's spawn must NOT inherit
# pad 1's write fd, or pad 1 could never see EOF once pad 2 exists.
test_cross_pad_fd_rule2() {
    local wd; wd="$(_case_dir case27)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          rig_create_pad 2 >/dev/null 2>&1
          pid1="$(rig_pad_field 1 pid)"
          pid2="$(rig_pad_field 2 pid)"
          fd1="${_MCSS_RIG_FDS[1]}"
          { exec {fd1}>&-; } 2>/dev/null || true
          gone=0
          for i in $(seq 1 80); do
              kill -0 "$pid1" 2>/dev/null || { gone=1; break; }
              sleep 0.1
          done
          echo "RESULT:PAD1_EXITED=$gone"
          kill -0 "$pid2" 2>/dev/null && echo "RESULT:PAD2_ALIVE=yes" || echo "RESULT:PAD2_ALIVE=no"
          unset "_MCSS_RIG_PIDS[1]" "_MCSS_RIG_FDS[1]" "_MCSS_RIG_UNIQS[1]" 2>/dev/null || true
          rm -f "$(rig_workdir)/pad1.fifo" "$(rig_workdir)/pad1.pid" 2>/dev/null || true
          rig_cleanup >/dev/null 2>&1' "$wd" case27
    _expect "27.1 pad 1 exits after its own fd closes (pad 2 stays live)" \
        "$(_result PAD1_EXITED)" "1"
    _expect "27.2 pad 2 was never affected" \
        "$(_result PAD2_ALIVE)" "yes"
}

# Item 28: rig_install_traps on a clean shell -> rc 0 + a non-empty EXIT
# trap; on a shell with a pre-existing EXIT trap -> rc 1, original unchanged.
test_install_traps_refuses_to_clobber() {
    local wd; wd="$(_case_dir case28)"
    _run 'rig_install_traps >/dev/null 2>&1
          echo "RESULT:CLEAN_RC=$?"
          t="$(trap -p EXIT)"
          [[ -n "$t" ]] && echo "RESULT:TRAP_SET=yes" || echo "RESULT:TRAP_SET=no"' \
        "$wd" case28a
    _expect "28.1 rig_install_traps on a clean shell -> rc 0" \
        "$(_result CLEAN_RC)" "0"
    _expect "28.2 EXIT trap is installed" "$(_result TRAP_SET)" "yes"

    _run 'trap "echo mytrap" EXIT
          rig_install_traps >/dev/null 2>&1
          echo "RESULT:REFUSE_RC=$?"
          t="$(trap -p EXIT)"
          [[ "$t" == *"echo mytrap"* ]] && echo "RESULT:UNCHANGED=yes" || echo "RESULT:UNCHANGED=no"' \
        "$wd" case28b
    _expect "28.3 rig_install_traps refuses an existing EXIT trap -> rc 1" \
        "$(_result REFUSE_RC)" "1"
    _expect "28.4 the original trap is left unchanged" \
        "$(_result UNCHANGED)" "yes"
}

# Item 29 — the #146 regression guard, and the single most valuable test in
# the suite: a child that sources the library, installs traps, creates a
# pad, then sleeps; SIGINT must make it exit 130 (not fall through into
# whatever comes after, per #146) AND the pad process must be gone. Run
# directly (not through `_run`) because this needs to signal a specific,
# still-running child process, which `$( )` capture cannot do.
test_sigint_end_to_end() {
    local wd script outfile
    wd="$(_case_dir case29)"
    script="$SUITE_TMP_ROOT/case29.script.sh"
    # The final wait (not a bare foreground `sleep 30`) is deliberate: bash
    # defers running a trap until the CURRENT foreground command finishes,
    # so a raw `sleep 30` would swallow the SIGINT for the full 30s instead
    # of reacting to it — backgrounding the sleep and `wait`-ing on it is the
    # standard idiom that lets the INT trap fire immediately instead.
    cat > "$script" <<INNEREOF
source "$LIB"
rig_init >/dev/null 2>&1 || exit 99
rig_install_traps >/dev/null 2>&1 || exit 98
rig_create_pad 1 >/dev/null 2>&1 || exit 97
echo "READY pid=\$(rig_pad_field 1 pid)"
sleep 30 &
wait \$!
INNEREOF
    outfile="$SUITE_TMP_ROOT/case29.out"
    : > "$outfile"

    # `set -m` (job control) around the launch is load-bearing, not
    # cosmetic: WITHOUT it, a background job (`&`) of a non-interactive
    # script shell gets SIGINT/SIGQUIT set to IGNORED per POSIX before exec,
    # and bash reflects that INHERITED ignore as a real (non-empty)
    # `trap -p INT` in the child — which is permanent for that process (a
    # `trap - INT` inside the child cannot undo a disposition that was
    # already SIG_IGN at shell startup). rig_install_traps would then see a
    # pre-existing trap and correctly refuse to clobber it, exactly as
    # designed — the bug is in how this harness launches the child, not in
    # the library. `set -m` gives the job its own process group with normal
    # (non-ignored) signal dispositions, matching how a real supervisor
    # would start this process. Reset with `set +m` right after so the rest
    # of the suite's job-control-off assumptions (e.g. no "Done" job
    # notifications on stderr) hold for every other test.
    set -m
    MCSS_WORKDIR="$wd" MCSS_RIG_ID=case29 MCSS_RIG_PAD_CMD="bash $FAKE_PAD" \
        bash "$script" > "$outfile" 2>&1 &
    local child_pid=$!
    set +m

    local pad_pid=""
    for _ in $(seq 1 100); do
        if grep -q '^READY pid=' "$outfile" 2>/dev/null; then
            pad_pid="$(grep -m1 '^READY pid=' "$outfile" | cut -d= -f2)"
            break
        fi
        sleep 0.1
    done

    kill -INT "$child_pid" 2>/dev/null

    # Bounded wait for the child's own exit status: a bare `wait` would be
    # unbounded, so a watchdog force-kills the child if it never reacts —
    # that would then correctly FAIL this test (rc != 130) instead of
    # hanging the suite.
    ( sleep 10
      kill -0 "$child_pid" 2>/dev/null && kill -KILL "$child_pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local watchdog=$!
    wait "$child_pid" 2>/dev/null
    local child_rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null || true

    local pad_gone="no"
    if [[ -n "$pad_pid" ]]; then
        for _ in $(seq 1 50); do
            kill -0 "$pad_pid" 2>/dev/null || { pad_gone="yes"; break; }
            sleep 0.1
        done
    fi

    _expect "29.1 SIGINT'd rig exits 130 (the #146 regression guard)" \
        "$child_rc" "130"
    _expect "29.2 SIGINT'd rig's pad process is gone" "$pad_gone" "yes"
}

# Item 30: no stdout leaks — for each command function, `$(fn …)` captures
# the empty string and returns promptly. This is the ONE place in the suite
# that deliberately calls a command function inside `$( )`: it exists to
# prove misuse doesn't HANG the capture (PRINCIPLES #8's every-backgrounded-
# process-redirects-to-a-file discipline already makes that safe), not to
# endorse the pattern — see uhid_rig.sh's own header for why callers must
# not do this in real code (it can still orphan a pad; that's a separate,
# accepted, documented hazard this test does not re-litigate).
test_no_stdout_leaks() {
    local wd

    wd="$(_case_dir case30-init)"
    _run 'out="$(timeout 15 rig_init)"; echo "RESULT:OUT=[$out]"' "$wd" c30i
    _expect "30.1 \$(rig_init) captures empty stdout, no hang" \
        "$(_result OUT)" "[]"

    wd="$(_case_dir case30-create)"
    _run 'rig_init >/dev/null 2>&1
          out="$(timeout 15 rig_create_pad 1)"
          echo "RESULT:OUT=[$out]"' "$wd" c30c
    _expect "30.2 \$(rig_create_pad) captures empty stdout, no hang" \
        "$(_result OUT)" "[]"

    wd="$(_case_dir case30-inject)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          out="$(timeout 15 rig_inject 1 "press BTN_SOUTH")"
          echo "RESULT:OUT=[$out]"
          rig_cleanup >/dev/null 2>&1' "$wd" c30j
    _expect "30.3 \$(rig_inject) captures empty stdout, no hang" \
        "$(_result OUT)" "[]"

    wd="$(_case_dir case30-destroy)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          out="$(timeout 15 rig_destroy_pad 1)"
          echo "RESULT:OUT=[$out]"' "$wd" c30d
    _expect "30.4 \$(rig_destroy_pad) captures empty stdout, no hang" \
        "$(_result OUT)" "[]"

    wd="$(_case_dir case30-cleanup)"
    _run 'rig_init >/dev/null 2>&1
          rig_create_pad 1 >/dev/null 2>&1
          rig_create_pad 2 >/dev/null 2>&1
          out="$(timeout 15 rig_cleanup)"
          echo "RESULT:OUT=[$out]"' "$wd" c30u
    _expect "30.5 \$(rig_cleanup) captures empty stdout, no hang" \
        "$(_result OUT)" "[]"
}

run_all_tests() {
    echo "=== uhid_rig.sh ==="
    test_default_uniq_values
    test_default_uniq_bad_index
    test_workdir_before_after_init
    test_rig_init_honors_rig_id
    test_double_source_is_safe
    test_pad_file_naming
    test_uhid_pad_contract_drift
    test_create_pad_basics
    test_pad_field_values
    test_pad_is_live_predicate
    test_create_pad_already_live
    test_create_pad_uniq_override
    test_inject_press_acked
    test_inject_rejected_command
    test_inject_untracked_index
    test_inject_after_external_kill
    test_destroy_pad_and_idempotency
    test_destroy_pad_kill_rung
    test_create_pad_never_ready
    test_burst_create
    test_recreate_cycle
    test_cleanup_all_and_twice
    test_foreign_pid_safety
    test_cross_rig_isolation
    test_eof_teardown_rule1
    test_cross_pad_fd_rule2
    test_install_traps_refuses_to_clobber
    test_sigint_end_to_end
    test_no_stdout_leaks
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
