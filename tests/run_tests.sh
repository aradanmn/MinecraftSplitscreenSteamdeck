#!/usr/bin/env bash
# =============================================================================
# Test runner — executes all bats test suites
# Usage:
#   ./tests/run_tests.sh                  # run all tests
#   ./tests/run_tests.sh unit             # run only unit tests
#   ./tests/run_tests.sh integration      # run only integration tests
#   ./tests/run_tests.sh --tap            # TAP output (for CI)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find bats — prefer local install, fall back to system bats
if [[ -x "$SCRIPT_DIR/bats-install/bin/bats" ]]; then
    BATS="$SCRIPT_DIR/bats-install/bin/bats"
elif command -v bats >/dev/null 2>&1; then
    BATS=$(command -v bats)
else
    echo "[ERROR] bats not found. Run: git clone --depth=1 https://github.com/bats-core/bats-core tests/bats && tests/bats/install.sh tests/bats-install"
    exit 1
fi

FILTER="${1:-all}"
TAP_FLAGS=()
[[ "${*}" == *"--tap"* ]] && TAP_FLAGS=(--tap)

echo ""
echo "=== Minecraft Splitscreen Test Suite ==="
echo "    bats: $($BATS --version)"
echo "    filter: $FILTER"
echo ""

pass=0
fail=0

run_suite() {
    local suite_dir="$1"
    local suite_name="$2"
    local tests=("$suite_dir"/*.bats)

    if [[ ${#tests[@]} -eq 0 || ! -f "${tests[0]}" ]]; then
        echo "  (no tests in $suite_name)"
        return
    fi

    echo "--- $suite_name ---"
    for test_file in "${tests[@]}"; do
        if "$BATS" "${TAP_FLAGS[@]}" "$test_file"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    echo ""
}

case "$FILTER" in
    unit)
        run_suite "$SCRIPT_DIR/unit" "Unit Tests"
        ;;
    integration)
        run_suite "$SCRIPT_DIR/integration" "Integration Tests"
        ;;
    all|*)
        run_suite "$SCRIPT_DIR/unit" "Unit Tests"
        run_suite "$SCRIPT_DIR/integration" "Integration Tests"
        ;;
esac

echo "=== Results: $pass suite(s) passed, $fail failed ==="

[[ $fail -eq 0 ]]
