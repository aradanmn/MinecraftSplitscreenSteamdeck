#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: runtime_context.sh — #45 paths/screen/constants resolvers
# =============================================================================
# All tests run the module in a fresh `bash -c` subshell with a controlled
# environment (readonly constants + resolver idempotency flags must not leak
# between cases). No hardware or display required: screen tests use the env
# override and --no-probe paths, which are deterministic everywhere.
# Run: bash tests/test_runtime_context.sh
# =============================================================================

readonly TEST_TOTAL=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RC_MODULE="$REPO_ROOT/modules/runtime_context.sh"

# The module honors legacy override env vars (N_SLOTS, INSTANCES_DIR, ...). If
# the developer's own shell exports any of them, they would leak into the plain
# `rc_run` subshells below and make cases pass/fail for the wrong reason — a
# CI/local split. Strip them from THIS shell so children inherit a clean base;
# cases that test an override set it explicitly via `env VAR=val`.
unset N_SLOTS INSTANCES_DIR LAUNCHER_EXEC SPLITSCREEN_SCREEN_W SPLITSCREEN_SCREEN_H \
      CONTROLLER_MONITOR_RAW_BINDING MCSS_LAUNCHER_ROOT MCSS_INSTANCES_DIR \
      MCSS_LAUNCHER_EXEC MCSS_SCREEN_W MCSS_SCREEN_H MCSS_MAX_PLAYERS \
      MCSS_STEAM_VENDOR_ID MCSS_STEAM_PRODUCT_ID MCSS_RAW_BINDING 2>/dev/null || true

TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
    local actual="$1" expected="$2" test_name="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $test_name — got \"$actual\""
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "[FAIL] $test_name — expected \"$expected\", got \"$actual\""
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# rc_run <bash-snippet> — fresh bash, module sourced first, snippet's stdout
# returned. env vars for the case are passed via `env` by the caller.
rc_run() {
    bash -c "set -euo pipefail; source '$RC_MODULE'; $1" 2>/dev/null
}

_scratch=$(mktemp -d)
trap 'rm -rf "$_scratch"' EXIT

# --- T1: constant defaults ---
out=$(rc_run 'echo "$MCSS_MAX_PLAYERS $MCSS_INSTANCE_PREFIX $MCSS_ACCOUNT_PREFIX $MCSS_WINDOW_TITLE_PREFIX"')
assert_equals "$out" "4 latestUpdate- P SplitscreenP" "T1: constants default values" || true

# --- T2: Steam Deck controller ids ---
out=$(rc_run 'echo "$MCSS_STEAM_VENDOR_ID:$MCSS_STEAM_PRODUCT_ID"')
assert_equals "$out" "28de:11ff" "T2: Deck built-in vendor/product ids" || true

# --- T3: N_SLOTS legacy override feeds MCSS_MAX_PLAYERS ---
out=$(env N_SLOTS=2 bash -c "set -euo pipefail; source '$RC_MODULE'; echo \$MCSS_MAX_PLAYERS" 2>/dev/null)
assert_equals "$out" "2" "T3: N_SLOTS legacy override honored" || true

# --- T4: CONTROLLER_MONITOR_RAW_BINDING legacy override feeds MCSS_RAW_BINDING ---
out=$(env CONTROLLER_MONITOR_RAW_BINDING=0 bash -c "set -euo pipefail; source '$RC_MODULE'; echo \$MCSS_RAW_BINDING" 2>/dev/null)
assert_equals "$out" "0" "T4: RAW_BINDING legacy override honored" || true

# --- T5: double-source is safe (readonly guards) ---
out=$(rc_run "source '$RC_MODULE'; echo OK")
assert_equals "$out" "OK" "T5: re-sourcing does not trip readonly errors" || true

# --- T6: mcss_resolve_paths detects launcher root from disk ---
mkdir -p "$_scratch/home6/.local/share/PrismLauncher/instances"
out=$(env HOME="$_scratch/home6" bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_paths; echo \$MCSS_LAUNCHER_ROOT" 2>/dev/null)
assert_equals "$out" "$_scratch/home6/.local/share/PrismLauncher" "T6: launcher root probed from disk (Prism)" || true

# --- T7: INSTANCES_DIR legacy override wins over detection ---
out=$(env HOME="$_scratch/home6" INSTANCES_DIR=/custom/instances bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_paths; echo \$MCSS_INSTANCES_DIR" 2>/dev/null)
assert_equals "$out" "/custom/instances" "T7: INSTANCES_DIR legacy override honored" || true

# --- T8: LAUNCHER_EXEC legacy override wins over cascade ---
out=$(env HOME="$_scratch/home6" LAUNCHER_EXEC=/my/launcher bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_paths; echo \$MCSS_LAUNCHER_EXEC" 2>/dev/null)
assert_equals "$out" "/my/launcher" "T8: LAUNCHER_EXEC legacy override honored" || true

# --- T9: AppRun FUSE workaround preferred over AppImage ---
mkdir -p "$_scratch/home9/.local/share/PolyMC/instances" "$_scratch/home9/.local/share/PolyMC/squashfs-root"
touch "$_scratch/home9/.local/share/PolyMC/PolyMC.AppImage" "$_scratch/home9/.local/share/PolyMC/squashfs-root/AppRun"
chmod +x "$_scratch/home9/.local/share/PolyMC/PolyMC.AppImage" "$_scratch/home9/.local/share/PolyMC/squashfs-root/AppRun"
out=$(env HOME="$_scratch/home9" bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_paths; echo \$MCSS_LAUNCHER_EXEC" 2>/dev/null)
assert_equals "$out" "$_scratch/home9/.local/share/PolyMC/squashfs-root/AppRun" "T9: AppRun preferred over AppImage" || true

# --- T10: mcss_instance_dir shape ---
out=$(env HOME="$_scratch/home9" bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_instance_dir 3" 2>/dev/null)
assert_equals "$out" "$_scratch/home9/.local/share/PolyMC/instances/latestUpdate-3" "T10: mcss_instance_dir shape" || true

# --- T11: screen env override wins WITHOUT --no-probe (override-first) ---
out=$(env SPLITSCREEN_SCREEN_W=1920 SPLITSCREEN_SCREEN_H=1080 bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_screen; echo \${MCSS_SCREEN_W}x\${MCSS_SCREEN_H}" 2>/dev/null)
assert_equals "$out" "1920x1080" "T11: screen override beats probes (override-first)" || true

# --- T12: --no-probe with no override → 1280x800 fallback (never 720) ---
out=$(rc_run 'mcss_resolve_screen --no-probe; echo "${MCSS_SCREEN_W}x${MCSS_SCREEN_H}"')
assert_equals "$out" "1280x800" "T12: --no-probe fallback is 1280x800" || true

# --- T13: --refresh re-resolves after override change ---
out=$(env SPLITSCREEN_SCREEN_W=800 SPLITSCREEN_SCREEN_H=600 bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_screen --no-probe; SPLITSCREEN_SCREEN_W=1920 SPLITSCREEN_SCREEN_H=1080 mcss_resolve_screen --refresh --no-probe; echo \${MCSS_SCREEN_W}x\${MCSS_SCREEN_H}" 2>/dev/null)
assert_equals "$out" "1920x1080" "T13: --refresh re-resolves dimensions" || true

# --- T14: mcss_exec_env_string emits set vars + extras, skips unset ---
out=$(env SPLITSCREEN_DEBUG_LOG=/tmp/x.log bash -c "set -euo pipefail; source '$RC_MODULE'; unset TEST_NUMBER MCSS_MODE 2>/dev/null || true; mcss_exec_env_string MCSS_NESTED_SESSION=1" 2>/dev/null)
case "$out" in
    *SPLITSCREEN_DEBUG_LOG=/tmp/x.log*MCSS_NESTED_SESSION=1*)
        if [[ "$out" != *TEST_NUMBER* && "$out" != *MCSS_MODE=* ]]; then
            assert_equals "ok" "ok" "T14: exec_env_string emits set vars + extras, skips unset" || true
        else
            assert_equals "$out" "(no TEST_NUMBER/MCSS_MODE)" "T14: exec_env_string emits set vars + extras, skips unset" || true
        fi
        ;;
    *)
        assert_equals "$out" "(...DEBUG_LOG + NESTED_SESSION=1...)" "T14: exec_env_string emits set vars + extras, skips unset" || true
        ;;
esac

# --- T15: mcss_exec_env_string includes MCSS_NESTED_SESSION (canonical list) ---
out=$(rc_run 'mcss_exec_env_string')
case "$out" in
    *MCSS_NESTED_SESSION=*) assert_equals "ok" "ok" "T15: exec_env_string carries MCSS_NESTED_SESSION" || true ;;
    *) assert_equals "$out" "(should contain MCSS_NESTED_SESSION)" "T15: exec_env_string carries MCSS_NESTED_SESSION" || true ;;
esac

# --- T16: exec_env_string self-resolves origin context (no prior resolve call) ---
out=$(env -u MCSS_ENV_CONTEXT XDG_CURRENT_DESKTOP=gamescope bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_exec_env_string" 2>/dev/null)
case "$out" in
    *MCSS_ENV_CONTEXT=gamescope*) assert_equals "ok" "ok" "T16: exec_env_string resolves context before emitting" || true ;;
    *) assert_equals "$out" "(should contain MCSS_ENV_CONTEXT=gamescope)" "T16: exec_env_string resolves context before emitting" || true ;;
esac

# --- T17: constants re-resolve per process (exported value does NOT beat a child override) ---
# Simulates a child that inherited the parent's resolved MCSS_MAX_PLAYERS=4 but
# was launched with its own N_SLOTS=2 override — the override must win.
out=$(env MCSS_MAX_PLAYERS=4 N_SLOTS=2 bash -c "set -euo pipefail; source '$RC_MODULE'; echo \$MCSS_MAX_PLAYERS" 2>/dev/null)
assert_equals "$out" "2" "T17: child N_SLOTS override beats inherited MCSS_MAX_PLAYERS" || true

# --- T18: mcss_resolve_screen --refresh retains last-good on an empty probe ---
# Prior good 1920x1080 (as if a previous resolution), refresh with no override
# and --no-probe (empty probe result) must NOT clobber it to the 1280x800 fallback.
out=$(env MCSS_SCREEN_W=1920 MCSS_SCREEN_H=1080 bash -c "set -euo pipefail; source '$RC_MODULE'; mcss_resolve_screen --refresh --no-probe; echo \${MCSS_SCREEN_W}x\${MCSS_SCREEN_H}" 2>/dev/null)
assert_equals "$out" "1920x1080" "T18: --refresh retains last-good dims on empty probe" || true

# --- T19: exec_env_string — extras come LAST so env(1) last-wins overrides canonical ---
out=$(rc_run 'mcss_exec_env_string MCSS_NESTED_SESSION=plasma')
case "$out" in
    *MCSS_NESTED_SESSION=0*MCSS_NESTED_SESSION=plasma*)
        assert_equals "ok" "ok" "T19: extra overrides canonical by position (last-wins)" || true ;;
    *MCSS_NESTED_SESSION=plasma*)
        # canonical =0 may be absent if unset in this env — extra alone is also correct
        assert_equals "ok" "ok" "T19: extra overrides canonical by position (last-wins)" || true ;;
    *)
        assert_equals "$out" "(should end with MCSS_NESTED_SESSION=plasma)" "T19: extra overrides canonical by position (last-wins)" || true ;;
esac

# --- T20: exec_env_string — word-unsafe value refused, not emitted corrupted ---
# .desktop Exec / env(1) do not shell-unquote, so a value with spaces must be
# refused loudly (caller passes it as its own quoted env arg instead).
out=$(rc_run 'mcss_exec_env_string "BAD_VAL=has space" GOOD=1')
if [[ "$out" != *"has"* && "$out" == *GOOD=1* ]]; then
    assert_equals "ok" "ok" "T20: word-unsafe extra refused; safe extras still emitted" || true
else
    assert_equals "$out" "(no BAD_VAL, GOOD=1 present)" "T20: word-unsafe extra refused; safe extras still emitted" || true
fi

# --- Summary ---
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

# Exit non-zero if any assertion failed — the contract every other tests/test_*.sh
# honors (an all-|| true suite that always exits 0 hides regressions from any
# pre-push / verify chain that gates on exit status).
[[ "$TESTS_FAILED" -eq 0 ]]
