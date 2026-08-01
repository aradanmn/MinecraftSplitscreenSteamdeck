#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: tests/lib/workdir.sh (#122)
# =============================================================================
# The scratch-directory path used to be spelled once per script — eight copies
# of "$HOME/splitscreen-hwtest-<stamp>.log" alone — and a single session left
# ~90 loose files in $HOME. These tests pin the one encoding that replaced it.
#
# The properties that matter, and why:
#   - The override wins. Callers that must redirect the tree (the SSH probe
#     runner pins an absolute remote path) depend on MCSS_WORKDIR beating both
#     other sources.
#   - Self-derivation works from ANY cwd. Probes get invoked by absolute path
#     from a Steam launch option and from run_all.sh, never with a reliable
#     working directory — a cwd-relative resolution would put artifacts
#     somewhere different every run, which is the bug being fixed.
#   - mcss_workdir creates nothing. It is the query half of the pair; a script
#     printing "results would go to X" must not mkdir X as a side effect.
#
# No hardware, no install, no Deck. Every case runs against a temp dir.
#
# Run: bash tests/test_workdir.sh
# =============================================================================

readonly TEST_TOTAL=15

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT_REAL="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly LIB="$REPO_ROOT_REAL/tests/lib/workdir.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then _pass "$name"
    else _fail "$name" "expected '$expected', got '$actual'"; fi
}

_setup() { TMPDIR_TEST="$(mktemp -d)"; }
_teardown() { [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"; TMPDIR_TEST=""; }
trap _teardown EXIT

# _run: Evaluate an expression in a CLEAN subshell that sources the lib fresh.
#
# Each case must start from a known environment: the lib is re-sourceable and
# reads MCSS_WORKDIR/REPO_ROOT at call time, so leaking either between cases
# would make results order-dependent. `env -u` clears both unless the case
# sets them explicitly.
# Inputs:
#   $1 — bash expression to run after sourcing the lib
#   $2 — optional cwd to run it from (default: the repo root)
# Outputs:
#   stdout — whatever the expression prints
_run() {
    local expr="$1" cwd="${2:-$REPO_ROOT_REAL}"
    ( cd "$cwd" && env -u MCSS_WORKDIR -u REPO_ROOT \
        bash -c "source '$LIB'; $expr" )
}

# _run_env: Same, but with explicit VAR=VAL assignments prepended.
_run_env() {
    local assigns="$1" expr="$2" cwd="${3:-$REPO_ROOT_REAL}"
    ( cd "$cwd" && env -u MCSS_WORKDIR -u REPO_ROOT \
        bash -c "$assigns; source '$LIB'; $expr" )
}

# --- T1: path resolution -----------------------------------------------------

test_root_is_repo_workdir() {
    local got; got="$(_run 'mcss_workdir')"
    _expect "T1.1 bare call resolves to <repo>/.workdir" \
        "$got" "$REPO_ROOT_REAL/.workdir"
}

test_subdir_is_joined() {
    local got; got="$(_run 'mcss_workdir hardware')"
    _expect "T1.2 subdir is appended" \
        "$got" "$REPO_ROOT_REAL/.workdir/hardware"
}

test_nested_subdir_is_joined() {
    local got; got="$(_run 'mcss_workdir probes/uhid')"
    _expect "T1.3 nested subdir is appended verbatim" \
        "$got" "$REPO_ROOT_REAL/.workdir/probes/uhid"
}

test_no_trailing_slash() {
    local got; got="$(_run 'mcss_workdir')"
    case "$got" in
        */) _fail "T1.4 root has no trailing slash" "got '$got'" ;;
        *)  _pass "T1.4 root has no trailing slash" ;;
    esac
}

# --- T2: precedence ----------------------------------------------------------
# MCSS_WORKDIR > REPO_ROOT > self-derivation. The ssh probe runner and the
# tests themselves rely on the first beating the rest.

test_override_wins_over_derivation() {
    local got; got="$(_run_env 'export MCSS_WORKDIR=/tmp/mcss-override' \
        'mcss_workdir')"
    _expect "T2.1 MCSS_WORKDIR overrides the derived root" \
        "$got" "/tmp/mcss-override"
}

test_override_wins_over_repo_root() {
    local got; got="$(_run_env \
        'export REPO_ROOT=/some/other/repo MCSS_WORKDIR=/tmp/mcss-override' \
        'mcss_workdir probes')"
    _expect "T2.2 MCSS_WORKDIR beats REPO_ROOT too" \
        "$got" "/tmp/mcss-override/probes"
}

test_repo_root_used_when_set() {
    local got; got="$(_run_env 'export REPO_ROOT=/some/other/repo' \
        'mcss_workdir hardware')"
    _expect "T2.3 REPO_ROOT is honoured when no override" \
        "$got" "/some/other/repo/.workdir/hardware"
}

# --- T3: cwd independence ----------------------------------------------------
# The whole point: a probe launched from / or from a Steam shortcut must write
# to the same place as one launched from the checkout.

test_same_result_from_unrelated_cwd() {
    _setup
    local from_repo from_tmp
    from_repo="$(_run 'mcss_workdir hardware')"
    from_tmp="$(_run 'mcss_workdir hardware' "$TMPDIR_TEST")"
    _expect "T3.1 resolution is cwd-independent" "$from_tmp" "$from_repo"
    _teardown
}

test_resolves_from_root_cwd() {
    local got; got="$(_run 'mcss_workdir' "/")"
    _expect "T3.2 resolves correctly even from /" \
        "$got" "$REPO_ROOT_REAL/.workdir"
}

# --- T4: command-query separation --------------------------------------------

test_query_creates_nothing() {
    _setup
    local target="$TMPDIR_TEST/scratch"
    _run_env "export MCSS_WORKDIR='$target'" 'mcss_workdir probes' >/dev/null
    if [[ -e "$target" ]]; then
        _fail "T4.1 mcss_workdir creates nothing" "$target was created"
    else
        _pass "T4.1 mcss_workdir creates nothing"
    fi
    _teardown
}

test_init_creates_the_tree() {
    _setup
    local target="$TMPDIR_TEST/scratch"
    _run_env "export MCSS_WORKDIR='$target'" 'mcss_workdir_init probes/uhid'
    if [[ -d "$target/probes/uhid" ]]; then
        _pass "T4.2 mcss_workdir_init creates nested dirs"
    else
        _fail "T4.2 mcss_workdir_init creates nested dirs" "missing $target/probes/uhid"
    fi
    _teardown
}

test_init_is_idempotent() {
    _setup
    local target="$TMPDIR_TEST/scratch" rc
    _run_env "export MCSS_WORKDIR='$target'" 'mcss_workdir_init probes'
    _run_env "export MCSS_WORKDIR='$target'" 'mcss_workdir_init probes'
    rc=$?
    _expect "T4.3 a second init still returns 0" "$rc" "0"
    _teardown
}

test_init_reports_failure() {
    # A path under a regular FILE can never be created — the honest answer is a
    # non-zero return, not a silent success that leaves callers writing into
    # the void.
    _setup
    local blocker="$TMPDIR_TEST/iamafile"
    : > "$blocker"
    local rc=0
    _run_env "export MCSS_WORKDIR='$blocker/nope'" 'mcss_workdir_init sub' \
        2>/dev/null || rc=$?
    if (( rc != 0 )); then
        _pass "T4.4 init returns non-zero when it cannot create"
    else
        _fail "T4.4 init returns non-zero when it cannot create" "returned 0"
    fi
    _teardown
}

# --- T5: re-sourcing ---------------------------------------------------------
# Hardware stages source helpers.sh (which sources this) both standalone and
# via run_all.sh; a second source must not explode under `set -u`.

test_double_source_is_safe() {
    local got
    got="$( cd "$REPO_ROOT_REAL" && env -u MCSS_WORKDIR -u REPO_ROOT \
        bash -c "set -euo pipefail; source '$LIB'; source '$LIB'; mcss_workdir x" )"
    _expect "T5.1 sourcing twice under set -u still resolves" \
        "$got" "$REPO_ROOT_REAL/.workdir/x"
}

# --- T6: the .workdir tree stays ignored -------------------------------------
# The convention is only a convention if git enforces it (#122). If .workdir/
# ever stopped being ignored, a Deck checkout would start offering run output
# for commit — and this whole change would have made things worse, not better.

test_workdir_is_gitignored() {
    local got
    got="$( cd "$REPO_ROOT_REAL" && git check-ignore -q .workdir/probe.txt \
        && echo ignored || echo tracked )"
    _expect "T6.1 .workdir/ is gitignored" "$got" "ignored"
}

run_all_tests() {
    echo "=== workdir.sh ==="
    test_root_is_repo_workdir
    test_subdir_is_joined
    test_nested_subdir_is_joined
    test_no_trailing_slash
    test_override_wins_over_derivation
    test_override_wins_over_repo_root
    test_repo_root_used_when_set
    test_same_result_from_unrelated_cwd
    test_resolves_from_root_cwd
    test_query_creates_nothing
    test_init_creates_the_tree
    test_init_is_idempotent
    test_init_reports_failure
    test_double_source_is_safe
    test_workdir_is_gitignored
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
