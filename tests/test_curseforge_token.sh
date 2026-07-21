#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: utilities.sh — CurseForge BYOK key resolution (#120)
# =============================================================================
# Verifies resolve_curseforge_api_token + get_curseforge_api_token:
#   - env var and key-file resolution (no network),
#   - non-interactive stdin (EOF) SKIPS without hanging (the #120 hang fix),
#   - a resolved key is inherited by a $(...) capture (the #120 per-mod
#     re-prompt fix — resolution happens once in the parent shell and is
#     exported).
# No network, no display, no Deck. Run: bash tests/test_curseforge_token.sh
# =============================================================================

readonly TEST_TOTAL=7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolate the key file into a scratch dir. Set BEFORE sourcing so the module's
# `: "${CURSEFORGE_KEY_FILE:=...}"` default keeps our path, not the real ~/.config one.
_scratch="$(mktemp -d)"
trap 'rm -rf "$_scratch"' EXIT
export CURSEFORGE_KEY_FILE="$_scratch/cf-key"

# shellcheck disable=SC1090  # runtime path, resolved above
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

# Reset module + env state between cases (the accessor short-circuits on the
# resolved flag; clear it and both key inputs each time).
reset_state() {
    unset _MCSS_CF_KEY_RESOLVED _MCSS_CF_API_KEY CURSEFORGE_API_KEY 2>/dev/null || true
    rm -f "$CURSEFORGE_KEY_FILE" 2>/dev/null || true
}

# --- T1: env var wins; accessor returns it (no resolve() needed) -----------
reset_state
export CURSEFORGE_API_KEY="env-key-123"
out="$(get_curseforge_api_token 2>/dev/null || true)"
assert_equals "$out" "env-key-123" "T1: env CURSEFORGE_API_KEY returned by accessor"

# --- T2: key file used when env is unset (whitespace stripped) --------------
reset_state
mkdir -p "$(dirname "$CURSEFORGE_KEY_FILE")"
printf '  file-key-456  \n' > "$CURSEFORGE_KEY_FILE"
out="$(get_curseforge_api_token 2>/dev/null || true)"
assert_equals "$out" "file-key-456" "T2: key file read + whitespace-stripped"

# --- T3: no key + non-interactive stdin (EOF) → resolve returns 1, no hang --
reset_state
rc=0
resolve_curseforge_api_token </dev/null >/dev/null 2>&1 || rc=$?
assert_equals "$rc" "1" "T3: no key + EOF stdin → resolve returns 1 (no hang)"
assert_equals "${_MCSS_CF_KEY_RESOLVED:-unset}" "1" "T3b: resolved flag set even when skipped"

# --- T4: resolved key inherited by a $() capture (the per-mod re-prompt fix) -
reset_state
export CURSEFORGE_API_KEY="inherit-789"
resolve_curseforge_api_token </dev/null >/dev/null 2>&1 || true
# Prove it's the RESOLVED/exported cache, not the env fallback: drop the env
# var, then the $()-captured accessor must still return the key.
unset CURSEFORGE_API_KEY
out="$(get_curseforge_api_token 2>/dev/null || true)"
assert_equals "$out" "inherit-789" "T4: resolved key inherited by \$() after env unset"

# --- T5: env key → resolve returns 0 and does NOT persist a key file --------
reset_state
export CURSEFORGE_API_KEY="env-key-nofile"
rc=0
resolve_curseforge_api_token </dev/null >/dev/null 2>&1 || rc=$?
assert_equals "$rc" "0" "T5: resolve returns 0 when env key present"
[[ -f "$CURSEFORGE_KEY_FILE" ]] && filestate="exists" || filestate="absent"
assert_equals "$filestate" "absent" "T5b: env key is not written to the key file"

# --- Summary ---
echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

# Exit non-zero if any assertion failed — the contract every tests/test_*.sh
# honors so a pre-push / CI gate can rely on exit status.
[[ "$TESTS_FAILED" -eq 0 ]]
