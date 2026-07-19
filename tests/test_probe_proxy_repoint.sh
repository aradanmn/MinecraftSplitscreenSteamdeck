#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: tests/probe-proxy-repoint.sh's pure verdict helpers (#38 HW-1)
# =============================================================================
# probe-proxy-repoint.sh is an operator-interactive Deck driver with no
# override hooks for simulating a real battery-death/reconnect cycle, so
# its Main flow itself is not cheaply testable end-to-end. Its v1.1 fix
# (HW-1 round 2) extracted the two comparisons that had a vacuous-match
# bug — _h6_identity_verdict and _h5_repoint_verdict — into small, pure,
# side-effect-free functions defined ABOVE a BASH_SOURCE[0]==$0 guard
# (same idiom as probe-evsieve-reconnect.sh's own v1.1 guard), so THIS
# suite can source the driver for just those two functions without
# running the operator-interactive flow.
#
# The bug these pin: an empty pre/post identity tally (record_virtual_
# node never actually running because the driver's own MCSS_PROXY_
# VIRT_DIR was unbound) compared "" == "" and "" != "NONE" — both true —
# and vacuously emitted H6_VIRT_JS=STABLE from nothing. Every case below
# that feeds an empty string must come back CAPTURE_EMPTY/FAIL, never a
# STABLE/RESUMES "pass".
#
# Run: bash tests/test_probe_proxy_repoint.sh
# =============================================================================

readonly TEST_TOTAL=9

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
readonly REPO_ROOT
readonly DRIVER="$REPO_ROOT/tests/probe-proxy-repoint.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# _source_driver: Source the driver into THIS shell, isolated from the
# real $HOME (mcss_resolve_paths runs at source time now — HW-1 round 2 —
# so a fresh, throwaway HOME/XDG_RUNTIME_DIR keeps that side effect off
# the real machine). MCSS_MODULES points nowhere real on purpose, so the
# driver's own `|| source "$HERE/../modules/controller_proxy.sh"`
# fallback fires and resolves this checkout's module, not a stale
# deployed copy.
# Inputs: $1 — tmp root to use as HOME/XDG_RUNTIME_DIR
_source_driver() {
    local tmp="$1"
    export HOME="$tmp/home"
    export XDG_RUNTIME_DIR="$tmp/xdg-runtime"
    export MCSS_MODULES="$tmp/no-such-modules-dir"
    export MCSS_PROBE_RESULTS="$tmp/results.txt"
    mkdir -p "$HOME"
    # shellcheck disable=SC1090
    source "$DRIVER"
}

# =============================================================================
# T1 — sourcing the driver does NOT run the operator-interactive Main
#      flow (the BASH_SOURCE[0]==$0 guard itself)
# =============================================================================
test_t1() {
    local tmp out
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    out=$(
        _source_driver "$tmp" 2>/dev/null
        echo "SOURCED_OK"
    )
    if [[ "$out" == *"SOURCED_OK"* && "$out" != *"D2-CONFIRM"* ]]; then
        _pass "T1 — sourcing the driver skips Main flow (guard works)"
    else
        _fail "T1" "banner/main-flow output leaked into sourcing: $out"
    fi
}

# =============================================================================
# T2 — _h6_identity_verdict: STABLE when every field matches and none is
#      NONE/empty
# =============================================================================
test_t2() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        local tally="realpath=/dev/input/event27 inode=123 majmin=13:59"
        tally+=" js=3"
        out=$(_h6_identity_verdict "$tally" "$tally")
        [[ "$out" == "STABLE" ]]
    ); then
        _pass "T2 — _h6_identity_verdict: identical real tallies -> STABLE"
    else
        _fail "T2" "expected STABLE for identical, well-formed tallies"
    fi
}

# =============================================================================
# T3 — _h6_identity_verdict: CHANGED when the inode differs
# =============================================================================
test_t3() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        pre="realpath=/dev/input/event27 inode=123 majmin=13:59 js=3"
        post="realpath=/dev/input/event27 inode=999 majmin=13:59 js=3"
        out=$(_h6_identity_verdict "$pre" "$post")
        [[ "$out" == "CHANGED" ]]
    ); then
        _pass "T3 — _h6_identity_verdict: differing inode -> CHANGED"
    else
        _fail "T3" "expected CHANGED when inode differs"
    fi
}

# =============================================================================
# T4 — HW-1 THE ACTUAL BUG: _h6_identity_verdict with BOTH tallies empty
#      (the exact on-Deck symptom — record_virtual_node's own command
#      substitution died before producing any output) must be
#      CAPTURE_EMPTY, never STABLE
# =============================================================================
test_t4() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        out=$(_h6_identity_verdict "" "")
        [[ "$out" == "CAPTURE_EMPTY" ]]
    ); then
        _pass "T4 — _h6_identity_verdict: pre=\"\" post=\"\" -> \
CAPTURE_EMPTY (never STABLE)"
    else
        _fail "T4" "empty/empty must be CAPTURE_EMPTY, not a vacuous STABLE"
    fi
}

# =============================================================================
# T5 — _h6_identity_verdict: one side empty (the other real) -> also
#      CAPTURE_EMPTY, never CHANGED-by-accident or STABLE
# =============================================================================
test_t5() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        real="realpath=/dev/input/event27 inode=123 majmin=13:59 js=3"
        out=$(_h6_identity_verdict "$real" "")
        [[ "$out" == "CAPTURE_EMPTY" ]]
    ); then
        _pass "T5 — _h6_identity_verdict: one side empty -> CAPTURE_EMPTY"
    else
        _fail "T5" "one empty tally must still yield CAPTURE_EMPTY"
    fi
}

# =============================================================================
# T6 — _h6_identity_verdict: the pre-existing NONE-sentinel guard (a
#      real, run-to-completion record_virtual_node failure) still holds
#      — CHANGED, not STABLE, even though both sides are identical
# =============================================================================
test_t6() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        none="realpath=NONE inode=NONE majmin=NONE js=NONE"
        out=$(_h6_identity_verdict "$none" "$none")
        [[ "$out" == "CHANGED" ]]
    ); then
        _pass "T6 — _h6_identity_verdict: identical NONE tallies -> \
CHANGED (not STABLE)"
    else
        _fail "T6" "identical NONE-sentinel tallies must not read STABLE"
    fi
}

# =============================================================================
# T7 — _h5_repoint_verdict: a real, non-empty capture -> RESUMES
# =============================================================================
test_t7() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        tally="types=3 codes=3 abs=0:0..255"
        out=$(_h5_repoint_verdict "$tally")
        [[ "$out" == "RESUMES" ]]
    ); then
        _pass "T7 — _h5_repoint_verdict: real capture -> RESUMES"
    else
        _fail "T7" "expected RESUMES for a non-empty capture tally"
    fi
}

# =============================================================================
# T8 — _h5_repoint_verdict: a well-formed EMPTY capture (capture_stream's
#      own "nothing arrived" shape) -> SILENT, the legitimate scientific
#      finding, not FAIL
# =============================================================================
test_t8() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        tally="types= codes=0 abs=none"
        out=$(_h5_repoint_verdict "$tally")
        [[ "$out" == "SILENT" ]]
    ); then
        _pass "T8 — _h5_repoint_verdict: well-formed empty capture -> \
SILENT"
    else
        _fail "T8" "expected SILENT for a well-formed but empty capture"
    fi
}

# =============================================================================
# T9 — HW-1: _h5_repoint_verdict with a LITERALLY empty string (capture_
#      stream itself never ran/crashed) -> FAIL, never silently folded
#      into SILENT
# =============================================================================
test_t9() {
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    if (
        _source_driver "$tmp" 2>/dev/null
        out=$(_h5_repoint_verdict "")
        [[ "$out" == "FAIL" ]]
    ); then
        _pass "T9 — _h5_repoint_verdict: literally empty tally -> FAIL \
(never a silent pass)"
    else
        _fail "T9" "a raw empty tally must be FAIL, not SILENT"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== probe-proxy-repoint verdict-helper test suite ==="
echo ""
test_t1
test_t2
test_t3
test_t4
test_t5
test_t6
test_t7
test_t8
test_t9
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
