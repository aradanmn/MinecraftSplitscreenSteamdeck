#!/usr/bin/env bash
# =============================================================================
# @file test_api_mocking.sh
# @description Tests for mod compatibility checking with mocked API responses.
#
# Overrides curl via tests/bin/ on PATH so no live network calls are made.
# Mocks _get_curseforge_token directly to avoid the openssl decrypt step.
# Tests both success paths (globals populated correctly) and failure paths
# (graceful handling of 404s and token failures).
#
# Usage:
#   bash tests/test_api_mocking.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULES_DIR="$PROJECT_DIR/modules"

# Prepend mock curl to PATH — handles both direct calls and timeout 15 curl ...
export PATH="$SCRIPT_DIR/bin:$PATH"

# =============================================================================
# Source modules in dependency order
# =============================================================================

# shellcheck source=../modules/version_info.sh
source "$MODULES_DIR/version_info.sh"
# shellcheck source=../modules/utilities.sh
source "$MODULES_DIR/utilities.sh"
# shellcheck source=../modules/path_configuration.sh
source "$MODULES_DIR/path_configuration.sh"
# shellcheck source=../modules/mod_management.sh
source "$MODULES_DIR/mod_management.sh"

# =============================================================================
# Mocks applied after sourcing (so utilities.sh definitions don't win)
# =============================================================================

# Silence print_* so test output isn't buried in installer noise.
# LOG_FILE=/dev/null prevents log() from returning 1 on short-circuit when
# LOG_FILE is unset, which would propagate through print_success() as a
# non-zero exit code and cause false failures on the success-path tests.
LOG_FILE=/dev/null
print_header()   { :; }
print_success()  { :; }
print_warning()  { :; }
print_error()    { :; }
print_info()     { :; }
print_progress() { :; }

# Bypass token download + openssl decryption entirely.
_get_curseforge_token() { echo "mock-api-key-for-testing"; }

# =============================================================================
# Assertion framework
# =============================================================================

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected: %s\n        actual:   %s\n" \
            "$desc" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        looking for: %s\n        in: %s\n" \
            "$desc" "$needle" "$haystack"
        (( FAIL++ )) || true
    fi
}

assert_return() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected rc: %s  actual rc: %s\n" \
            "$desc" "$expected_rc" "$actual_rc"
        (( FAIL++ )) || true
    fi
}

run_test() { echo "--- $1"; }

reset_mod_globals() {
    SUPPORTED_MODS=()
    MOD_URLS=()
    MOD_IDS=()
    MOD_TYPES=()
    MOD_DEPENDENCIES=()
}

# =============================================================================
# Test 1: Modrinth — compatible version populates output globals
# Fixture: modrinth_P7dR8mSH.json has a 1.21.4 release of Fabric API.
# =============================================================================
run_test "Modrinth: compatible version populates SUPPORTED_MODS and MOD_URLS"
MC_VERSION="1.21.4"
reset_mod_globals
rc=0; check_modrinth_mod "Fabric API" "P7dR8mSH" || rc=$?

assert_return "return code 0 (compatible)"       "0" "$rc"
assert_eq     "SUPPORTED_MODS[0] is Fabric API"  "Fabric API" "${SUPPORTED_MODS[0]:-}"
assert_contains "MOD_URLS[0] contains CDN URL"   "cdn.modrinth.com" "${MOD_URLS[0]:-}"
assert_contains "MOD_URLS[0] contains jar filename" ".jar" "${MOD_URLS[0]:-}"
assert_eq     "MOD_TYPES[0] is modrinth"         "modrinth" "${MOD_TYPES[0]:-}"

# =============================================================================
# Test 2: Modrinth — incompatible version returns 1, globals unchanged
# Fixture: modrinth_OLDMOD.json only has 1.20.4 releases.
# =============================================================================
run_test "Modrinth: incompatible version returns 1 and does not populate globals"
MC_VERSION="1.21.4"
reset_mod_globals
rc=0; check_modrinth_mod "Old Mod" "OLDMOD" || rc=$?

assert_return "return code 1 (no match)"         "1" "$rc"
assert_eq     "SUPPORTED_MODS is empty"          "0" "${#SUPPORTED_MODS[@]}"
assert_eq     "MOD_URLS is empty"                "0" "${#MOD_URLS[@]}"

# =============================================================================
# Test 3: Modrinth — API 404 returns 1 gracefully
# No fixture file exists for mod ID "NOTFOUND", so mock curl returns 404.
# =============================================================================
run_test "Modrinth: API 404 returns 1 without crashing"
MC_VERSION="1.21.4"
reset_mod_globals
rc=0; check_modrinth_mod "Missing Mod" "NOTFOUND" || rc=$?

assert_return "return code 1 (API error)"        "1" "$rc"
assert_eq     "SUPPORTED_MODS is empty"          "0" "${#SUPPORTED_MODS[@]}"

# =============================================================================
# Test 4: Modrinth — required dependencies are captured in MOD_DEPENDENCIES
# Fixture: modrinth_WITHDEPS.json has a dependency on P7dR8mSH.
# =============================================================================
run_test "Modrinth: required dependencies are captured in MOD_DEPENDENCIES"
MC_VERSION="1.21.4"
reset_mod_globals
rc=0; check_modrinth_mod "Mod With Deps" "WITHDEPS" || rc=$?

assert_return "return code 0 (compatible)"       "0" "$rc"
assert_contains "MOD_DEPENDENCIES[0] has P7dR8mSH" "P7dR8mSH" "${MOD_DEPENDENCIES[0]:-}"

# =============================================================================
# Test 5: CurseForge — compatible version populates output globals
# Fixture: curseforge_317269.json has a 1.21.4 release of Controllable.
# =============================================================================
run_test "CurseForge: compatible version populates SUPPORTED_MODS and MOD_URLS"
MC_VERSION="1.21.4"
reset_mod_globals
_CF_TOKEN_CACHE=""  # reset token cache so mock is called
rc=0; check_curseforge_mod "Controllable" "317269" || rc=$?

assert_return "return code 0 (compatible)"       "0" "$rc"
assert_eq     "SUPPORTED_MODS[0] is Controllable" "Controllable" "${SUPPORTED_MODS[0]:-}"
assert_contains "MOD_URLS[0] contains CDN URL"   "forgecdn.net" "${MOD_URLS[0]:-}"
assert_eq     "MOD_TYPES[0] is curseforge"       "curseforge" "${MOD_TYPES[0]:-}"

# =============================================================================
# Test 6: CurseForge — token failure returns 1 gracefully
# Override _get_curseforge_token to simulate a failed download/decrypt.
# =============================================================================
run_test "CurseForge: token fetch failure returns 1 without crashing"
MC_VERSION="1.21.4"
reset_mod_globals
_get_curseforge_token() { return 1; }  # simulate failure
rc=0; check_curseforge_mod "Controllable" "317269" || rc=$?
_get_curseforge_token() { echo "mock-api-key-for-testing"; }  # restore

assert_return "return code 1 (token error)"      "1" "$rc"
assert_eq     "SUPPORTED_MODS is empty"          "0" "${#SUPPORTED_MODS[@]}"

# =============================================================================
# Test 7: CurseForge — API 404 returns 1 gracefully
# No fixture for project ID 999999, so mock curl returns 404.
# =============================================================================
run_test "CurseForge: API 404 returns 1 without crashing"
MC_VERSION="1.21.4"
reset_mod_globals
_CF_TOKEN_CACHE=""
rc=0; check_curseforge_mod "Missing Mod" "999999" || rc=$?

assert_return "return code 1 (API error)"        "1" "$rc"
assert_eq     "SUPPORTED_MODS is empty"          "0" "${#SUPPORTED_MODS[@]}"

# =============================================================================
# Summary
# =============================================================================
echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
