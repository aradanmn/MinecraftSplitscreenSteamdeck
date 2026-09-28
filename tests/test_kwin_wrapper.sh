#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: _kwin_wrapper_script (#198)
# =============================================================================
# #198: on hosts where /usr/bin/kwin_wayland carries a file capability (seen on
# Bazzite/Framework Desktop: cap_sys_nice), execve makes the nested kwin
# non-dumpable, so mangoapp's fdinfo scan of it gets EACCES — which MangoHud
# 0.8.4 doesn't catch, so it aborts. MCSS_NESTED_KWIN_NNP=1 wraps the nested
# kwin under `setpriv --no-new-privs` so the capability grant is refused at
# exec, keeping it dumpable. Default is off (PRINCIPLES #2) until Deck-validated.
#
# _kwin_wrapper_script is pure (stdout only, no side effects), so this suite
# calls it directly instead of exercising the full nested-session machinery —
# safe to run anywhere, including LXC 105 (no processes spawned/killed).
#
# Each case sources minecraftSplitscreen.sh in its OWN bash subprocess (via
# `env ... bash -c`) rather than once in this shell: MCSS_NESTED_KWIN_NNP goes
# `readonly` the moment runtime_context.sh's constants block runs (the
# _MCSS_CONSTANTS_LOCKED house pattern), so toggling it between cases in one
# process isn't possible — a fresh process per case sidesteps that instead of
# fighting it.
#
# Run: bash tests/test_kwin_wrapper.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

FAILURES=0
PASSES=0
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "[FAIL] $desc — expected to find: $needle" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
        PASSES=$((PASSES + 1))
    fi
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[FAIL] $desc — did not expect to find: $needle" >&2
        echo "  --- actual ---" >&2
        echo "$haystack" | sed 's/^/  /' >&2
        FAILURES=$((FAILURES + 1))
    else
        echo "[PASS] $desc"
        PASSES=$((PASSES + 1))
    fi
}

# _wrapper_out: run _kwin_wrapper_script W H in a fresh bash process with the
# given MCSS_NESTED_KWIN_NNP and PATH, so the readonly lock from a prior case
# never carries over. $1=nnp $2=W $3=H $4=PATH (optional; inherited if empty).
_wrapper_out() {
    local nnp="$1" w="$2" h="$3" fake_path="${4:-$PATH}"
    env MCSS_NESTED_KWIN_NNP="$nnp" PATH="$fake_path" bash -c '
        source "$1/minecraftSplitscreen.sh"
        _kwin_wrapper_script "$2" "$3"
    ' _ "$REPO_ROOT" "$w" "$h" 2>/dev/null
}

# --- Case 1: flag off (default) — unchanged plain wrapper ------------------
out="$(_wrapper_out 0 1280 800)"
assert_contains     "flag off: shebang present" "$out" '#!/bin/bash'
assert_contains     "flag off: invokes kwin_wayland_wrapper with resolved size" \
    "$out" '/usr/bin/kwin_wayland_wrapper --width 1280 --height 800 --no-lockscreen "$@"'
assert_not_contains "flag off: does not wrap with setpriv" "$out" 'setpriv'

# --- Case 2: flag on, setpriv present — wrapped with --no-new-privs --------
if command -v setpriv >/dev/null 2>&1; then
    out="$(_wrapper_out 1 1280 800)"
    assert_contains "flag on: wraps with setpriv --no-new-privs" \
        "$out" 'setpriv --no-new-privs /usr/bin/kwin_wayland_wrapper'
    assert_contains "flag on: still passes resolved size through" \
        "$out" '--width 1280 --height 800 --no-lockscreen "$@"'
else
    echo "[SKIP] flag-on/setpriv-present case — setpriv not installed on this machine" >&2
fi

# --- Case 3: flag on, setpriv missing — fails open to the plain wrapper ----
# Shadow the `command` builtin (exported to the child bash below) so only
# `command -v setpriv` reports missing — everything else the sourcing chain
# needs (dirname, readlink, grep, ...) still resolves normally. Simpler and
# more surgical than emptying PATH, which breaks sourcing itself.
command() {
    [[ "$1" == "-v" && "$2" == "setpriv" ]] && return 1
    builtin command "$@"
}
export -f command
out="$(_wrapper_out 1 1280 800)"
unset -f command
assert_not_contains "flag on, setpriv missing: fails open (no setpriv wrap)" "$out" 'setpriv'
assert_contains     "flag on, setpriv missing: still a valid plain wrapper" \
    "$out" '/usr/bin/kwin_wayland_wrapper --width 1280 --height 800 --no-lockscreen "$@"'

echo
# Standard summary footer — the line .github/workflows/ci.yml parses for every
# suite (X/Y tests passed.); exit status is the gate.
echo "$PASSES/$((PASSES + FAILURES)) tests passed."
if (( FAILURES == 0 )); then
    exit 0
else
    exit 1
fi
