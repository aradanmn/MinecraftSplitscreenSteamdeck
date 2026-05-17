#!/usr/bin/env bash
# =============================================================================
# @file grade.sh
# @description Master test runner — grades the codebase against all test suites.
#
# Run this before marking any task complete. Exit 0 means all suites pass.
# On failure, the failing suite's output is always shown.
#
# Usage:
#   bash tests/grade.sh            # per-suite summary
#   bash tests/grade.sh --verbose  # full output from every suite
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASS=0
FAIL=0

run_suite() {
    local name="$1"; shift
    local tmpout
    tmpout="$(mktemp)"

    if ( cd "$PROJECT_DIR" && eval "$*" ) > "$tmpout" 2>&1; then
        printf "  PASS  %s\n" "$name"
        (( PASS++ )) || true
        $VERBOSE && cat "$tmpout"
    else
        printf "  FAIL  %s\n" "$name"
        (( FAIL++ )) || true
        cat "$tmpout"
    fi
    rm -f "$tmpout"
}

echo "=== Grade: $(date '+%Y-%m-%d %H:%M') ==="
echo ""

echo "-- Structural --"
run_suite "Fixture integrity"          "bash tests/check-fixture.sh"

echo ""
echo "-- Unit tests --"
run_suite "Utility functions (BATS)"   "bats tests/test_utilities.bats"
run_suite "Path configuration (BATS)"  "bats tests/test_path_configuration.bats"
run_suite "Instance creation (BATS)"   "bats tests/test_instance_creation.bats"
run_suite "Mod API compatibility"      "bash tests/test_api_mocking.sh"

echo ""
echo "-- Behavioral --"
run_suite "Dynamic mode event loop"    "bash tests/test_dynamic_mode.sh"

echo ""
TOTAL=$(( PASS + FAIL ))
printf "Result: %d/%d suites passed\n" "$PASS" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
    echo "NOT READY — fix failing suites before marking complete."
    exit 1
fi
echo "READY — all suites pass."
