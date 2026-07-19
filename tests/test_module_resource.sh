#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: modules/*.sh re-source safety
# =============================================================================
# Regression test for the HW-1 on-Deck abort: tests/hardware/run_all.sh
# `source`s every stage script into ONE shell, so any module it sources more
# than once (stage1 and stage2 both sourcing dock_detection.sh, for example)
# is sourced TWICE in that one process. An unguarded top-level `readonly`
# constants block aborts the whole suite on the second source with
# "readonly variable" — modules are SUPPOSED to be idempotently re-sourceable
# (dock_detection.sh's own header already claims this for runtime_context.sh;
# the constants blocks must honor the same contract — the house pattern is
# runtime_context.sh's `_MCSS_CONSTANTS_LOCKED` sentinel guard).
#
# This suite sources every module TWICE in the same `set -euo pipefail`
# shell and asserts: exit 0, and no stderr/stdout output from either source
# (a clean module defines functions/constants silently). Runtime modules are
# enumerated dynamically from modules/runtime_modules.list (#49: the ONE
# manifest) so a newly-added runtime module is automatically covered;
# installer-only modules (never in that manifest) are listed statically
# below, mirroring INSTALLER_MODULE_FILES in
# install-minecraft-splitscreen.sh.
#
# Run: bash tests/test_module_resource.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODULES_DIR="$REPO_ROOT/modules"
MANIFEST="$MODULES_DIR/runtime_modules.list"

# Installer-only modules (#7.2/T7.2 in test_installer.sh: 11 of them, never
# deployed to TARGET_DIR/modules/ and never in runtime_modules.list). Static
# on purpose — mirrors INSTALLER_MODULE_FILES in
# install-minecraft-splitscreen.sh, which is itself a literal array.
INSTALLER_MODULES=(
    utilities.sh
    java_management.sh
    evsieve_management.sh
    launcher_setup.sh
    version_management.sh
    lwjgl_management.sh
    mod_management.sh
    instance_creation.sh
    steam_integration.sh
    desktop_launcher.sh
    main_workflow.sh
)

# Runtime modules: dynamically enumerated from the ONE manifest (#49) so
# future additions are covered automatically without editing this file.
RUNTIME_MODULES=()
while IFS= read -r _mod; do
    RUNTIME_MODULES+=("$_mod")
done < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST")

if (( ${#RUNTIME_MODULES[@]} == 0 )); then
    echo "[FAIL] could not read any modules from $MANIFEST" >&2
    exit 1
fi

readonly TEST_TOTAL=$(( ${#RUNTIME_MODULES[@]} + ${#INSTALLER_MODULES[@]} ))

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# _test_double_source <module_file>: source it twice in one subshell — the
# same shape of failure as run_all.sh sourcing every stage into one shell.
# PASS iff the subshell exits 0 and neither source wrote any output (a clean
# module only defines functions/constants; anything printed means a warning
# or an error escaped to stdout/stderr).
_test_double_source() {
    local mod="$1"
    local path="$MODULES_DIR/$mod"

    if [[ ! -f "$path" ]]; then
        _fail "$mod" "module file not found at $path"
        return
    fi

    local out rc=0
    out=$(
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$path"
        # shellcheck disable=SC1090
        source "$path"
        echo "__DOUBLE_SOURCE_OK__"
    ) 2>&1 || rc=$?

    if (( rc == 0 )) && [[ "$out" == "__DOUBLE_SOURCE_OK__" ]]; then
        _pass "$mod — double-source clean (exit 0, no output)"
    elif (( rc == 0 )); then
        _fail "$mod" "double-source produced unexpected output: ${out}"
    else
        _fail "$mod" "double-source failed (exit=$rc): ${out}"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== module re-source safety test suite ==="
echo ""

for _mod in "${RUNTIME_MODULES[@]}"; do
    _test_double_source "$_mod"
done
for _mod in "${INSTALLER_MODULES[@]}"; do
    _test_double_source "$_mod"
done

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
