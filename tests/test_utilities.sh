#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: utilities.sh — run_with_spinner (evsieve build progress indicator)
# =============================================================================
# run_with_spinner runs a long quiet command with a live busy indicator. The
# animated path is TTY-only and stderr-cosmetic; these tests force the
# NON-interactive (inline) path with `2>/dev/null` (stderr not a TTY) so they
# are deterministic in CI and in a terminal alike, and assert the contract that
# matters: exit-status + stdout passthrough, and that the label never leaks to
# stdout (stdout stays the data protocol). Run: bash tests/test_utilities.sh
# =============================================================================

readonly TEST_TOTAL=13

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/modules/utilities.sh"

TESTS_PASSED=0
TESTS_FAILED=0
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

# T1 — success maps to 0
rc=0; run_with_spinner "build" true 2>/dev/null || rc=$?
assert_equals "$rc" "0" "T1: returns 0 when command succeeds"

# T2 — a failing command's non-zero status propagates
rc=0; run_with_spinner "build" false 2>/dev/null || rc=$?
assert_equals "$rc" "1" "T2: propagates non-zero (false → 1)"

# T2b — the EXACT exit code propagates (e.g. a timeout would be 124)
rc=0; run_with_spinner "build" bash -c 'exit 7' 2>/dev/null || rc=$?
assert_equals "$rc" "7" "T2b: propagates the exact exit code (7)"

# T3 — arguments are passed through to the command
rc=0; run_with_spinner "cmp" test 5 -eq 5 2>/dev/null || rc=$?
assert_equals "$rc" "0" "T3: passes args through to the command"

# T4 — the command's stdout passes through; the label does NOT ride on stdout
out="$(run_with_spinner "SECRET-LABEL" printf 'hello' 2>/dev/null)"
assert_equals "$out" "hello" "T4: command stdout passes through (label off stdout)"

# T5 — a silent command leaves stdout empty (the label went to stderr only)
out="$(run_with_spinner "SECRET-LABEL" true 2>/dev/null)"
assert_equals "$out" "" "T5: label goes to stderr, stdout stays clean"

# =============================================================================
# mcss_prompt (#185) — --yes was a no-op and two installer prompts were bare
# `read`s under `set -e`; a real EOF killed the whole install with no error
# message. These pin the three paths: ASSUME_YES skips the read outright, a
# genuine EOF falls back to its own (possibly different) default, and a real
# answer on stdin is used verbatim over either default.
# =============================================================================

# T6 — ASSUME_YES=true skips the read entirely: stdin offers a real answer
# ("REAL-ANSWER") that would prove the read ran if it were ever attempted;
# yes_default must win regardless.
out=""
out=$(ASSUME_YES=true bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "YES-DEFAULT" "EOF-DEFAULT" result
    echo "$result"
' <<< "REAL-ANSWER" 2>/dev/null)
assert_equals "$out" "YES-DEFAULT" "T6: ASSUME_YES=true uses yes_default, never reads stdin"

# T7 — no ASSUME_YES, stdin is a genuine EOF (< /dev/null): falls back to
# eof_default, not yes_default — the two must be independently selectable.
out=$(bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "YES-DEFAULT" "EOF-DEFAULT" result
    echo "$result"
' < /dev/null 2>/dev/null)
assert_equals "$out" "EOF-DEFAULT" "T7: a genuine EOF uses eof_default"

# T8 — ASSUME_YES=false explicitly behaves identically to it being unset
# (T7) — false must not be treated as truthy by a loose string check.
out=$(ASSUME_YES=false bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "YES-DEFAULT" "EOF-DEFAULT" result
    echo "$result"
' < /dev/null 2>/dev/null)
assert_equals "$out" "EOF-DEFAULT" "T8: ASSUME_YES=false behaves like unset"

# T9 — a real, live answer on stdin wins over BOTH defaults: mcss_prompt must
# still actually prompt (not always short-circuit) when there is real input
# and --yes was not requested.
out=$(bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "YES-DEFAULT" "EOF-DEFAULT" result
    echo "$result"
' <<< "actual-user-input" 2>/dev/null)
assert_equals "$out" "actual-user-input" "T9: a real answer overrides both defaults"

# T10 — the two defaults are independently addressable in one process: this
# is what lets the Steam-integration call site default to "y" under --yes
# while a bare EOF there still defaults to "n" (an unintended EOF must never
# silently perform an action with real side effects nobody asked for).
out=$(ASSUME_YES=true bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "p1: " "y" "n" r1
    mcss_prompt "p2: " "n" "n" r2
    echo "$r1,$r2"
' < /dev/null 2>/dev/null)
assert_equals "$out" "y,n" "T10: two prompts in one run pick their own yes_default independently"

# T11 — mcss_prompt's own status messages go to stderr, never stdout — a
# caller capturing the result via $(...) must get ONLY the answer.
out=$(ASSUME_YES=true bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "clean" "dirty" result
    echo "$result"
' <<< "x" 2>/dev/null)
assert_equals "$out" "clean" "T11: stdout carries only the answer, no status noise"

# T12 — a blank Enter (one newline) is a SUCCESSFUL read returning an empty
# string, not an EOF failure — bash's own subtlety, and the exact mechanism
# version_management.sh's "[Enter] = latest" prompt depends on. eof_default
# is deliberately set to something ELSE here so a bug that confuses "read
# succeeded with nothing" for "read failed via EOF" would be caught: if
# mcss_prompt ever mistook the two, this would return eof_default instead.
out=$(bash -c '
    source "'"$REPO_ROOT"'/modules/utilities.sh"
    mcss_prompt "ignored: " "YES-DEFAULT" "WRONG-EOF-DEFAULT" result
    echo "[$result]"
' <<< "" 2>/dev/null)
assert_equals "$out" "[]" "T12: a blank Enter is a successful empty read, not EOF"

# --- Summary ---
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
[[ "$TESTS_FAILED" -eq 0 ]]
