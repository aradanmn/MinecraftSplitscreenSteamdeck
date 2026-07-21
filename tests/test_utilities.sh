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

readonly TEST_TOTAL=6

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

# --- Summary ---
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
[[ "$TESTS_FAILED" -eq 0 ]]
