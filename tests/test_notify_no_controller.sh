#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: _notify_no_controller_docked (#125)
# =============================================================================
# #125: docked_flow's no-controller startup timeout used to be log-only,
# reading as a silent crash (error sounds, black screen, kicked back to the
# library, no explanation — the reason was only visible in the debug log).
# _notify_no_controller_docked wraps the fix: a best-effort mcss_notify_user
# call, self-dismissing after 8s (PRINCIPLES #6 — a user with no controller
# connected has no way to dismiss a modal dialog themselves).
#
# This suite ONLY calls the extracted notify wrapper directly — never
# docked_flow itself, which spawns real monitors/FIFO machinery and must
# never be exercised raw in this environment (see the test_orchestrator kill
# hazard memory: fixture PIDs can real-kill unrelated processes here). Source
# minecraftSplitscreen.sh (which defines every function via `source`, no
# flow is *run*) to reach the function, exactly like test_kwin_wrapper.sh and
# test_home_bwrap_bind.sh already do safely.
#
# Run: bash tests/test_notify_no_controller.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

FAILURES=0
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "[FAIL] $desc — expected to find: $needle" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
    fi
}
assert_equals() {
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "[FAIL] $desc — expected '$expected', got '$actual'" >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
    fi
}

# shellcheck source=/dev/null
source "$REPO_ROOT/minecraftSplitscreen.sh"

if ! declare -f _notify_no_controller_docked >/dev/null 2>&1; then
    echo "[FAIL] _notify_no_controller_docked not defined after sourcing minecraftSplitscreen.sh" >&2
    exit 1
fi

# --- Case 1: mcss_notify_user available — called with title/body/timeout ---
_CALL_LOG="$(mktemp)"
trap 'rm -f "$_CALL_LOG"' EXIT
mcss_notify_user() { printf '%s\n' "$*" >> "$_CALL_LOG"; }
_notify_no_controller_docked
_calls="$(cat "$_CALL_LOG")"
assert_equals "exactly one mcss_notify_user call" "$(wc -l < "$_CALL_LOG" | tr -d ' ')" "1"
assert_contains "title is Minecraft Splitscreen" "$_calls" "Minecraft Splitscreen"
assert_contains "message explains WHY (no controller)" "$_calls" "No controller detected"
assert_contains "message explains WHAT'S NEEDED (external controller)" "$_calls" "external controller"
assert_contains "self-dismisses (bounded, not an unbounded modal — PRINCIPLES #6)" "$_calls" "8"
unset -f mcss_notify_user

# --- Case 2: mcss_notify_user unavailable — no-op, does not error -----------
> "$_CALL_LOG"
unset -f mcss_notify_user 2>/dev/null || true
if declare -f mcss_notify_user >/dev/null 2>&1; then
    echo "[FAIL] setup: mcss_notify_user should be undefined for this case" >&2
    FAILURES=$((FAILURES + 1))
else
    if _notify_no_controller_docked; then
        echo "[PASS] no-op when mcss_notify_user is unavailable (fails open, no error)"
    else
        echo "[FAIL] _notify_no_controller_docked should not error when mcss_notify_user is missing" >&2
        FAILURES=$((FAILURES + 1))
    fi
fi

echo
if (( FAILURES == 0 )); then
    echo "[OK] all _notify_no_controller_docked cases passed"
    exit 0
else
    echo "[FAIL] $FAILURES case(s) failed"
    exit 1
fi
