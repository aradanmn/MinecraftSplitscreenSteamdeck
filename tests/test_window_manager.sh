#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: window_manager.sh
# =============================================================================
# Geometry computation tests only — no windows spawned, no display required.
# Run: DISPLAY= bash tests/test_window_manager.sh
# =============================================================================

readonly TEST_TOTAL=9

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/modules/window_manager.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
    echo "[PASS] $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_fail() {
    echo "[FAIL] $1 — $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# Test T3.1 — compute_grid_mode: all slot combinations
# =============================================================================
test_t3_1() {
    local test_failed=0
    local tests_run=0

    local cases=(
        "1:full"
        "1 2:half"
        "2:half"
        "1 3:quad"
        "1 2 3:quad"
        "3:quad"
        "4:quad"
        "1 2 3 4:quad"
        "2 4:quad"
    )

    local entry
    for entry in "${cases[@]}"; do
        local input="${entry%%:*}"
        local expected="${entry##*:}"
        tests_run=$((tests_run + 1))

        local actual
        actual=$(compute_grid_mode "$input")
        if [[ "$actual" != "$expected" ]]; then
            _fail "T3.1.$tests_run" "slots='$input': expected '$expected', got '$actual'"
            test_failed=1
        fi
    done

    if (( test_failed == 0 )); then
        _pass "T3.1 — compute_grid_mode: all 9 cases correct"
    fi
}

# =============================================================================
# Test T3.2 — compute_slot_geometry, full mode, 1920×1080
# =============================================================================
test_t3_2() {
    local result
    result=$(compute_slot_geometry 1 full 1920 1080)
    if [[ "$result" == "0 0 1920 1080" ]]; then
        _pass "T3.2 — full mode slot 1: 0 0 1920 1080"
    else
        _fail "T3.2" "expected '0 0 1920 1080', got '$result'"
    fi
}

# =============================================================================
# Test T3.3 — compute_slot_geometry, half mode, 1920×1080
# =============================================================================
test_t3_3() {
    local test_failed=0

    local r1
    r1=$(compute_slot_geometry 1 half 1920 1080)
    if [[ "$r1" != "0 0 1920 540" ]]; then
        _fail "T3.3a" "slot 1: expected '0 0 1920 540', got '$r1'"
        test_failed=1
    fi

    local r2
    r2=$(compute_slot_geometry 2 half 1920 1080)
    if [[ "$r2" != "0 540 1920 540" ]]; then
        _fail "T3.3b" "slot 2: expected '0 540 1920 540', got '$r2'"
        test_failed=1
    fi

    if (( test_failed == 0 )); then
        _pass "T3.3 — half mode slots 1-2: correct"
    fi
}

# =============================================================================
# Test T3.4 — compute_slot_geometry, quad mode, 1920×1080
# =============================================================================
test_t3_4() {
    local test_failed=0

    local cases=(
        "1:0 0 960 540"
        "2:960 0 960 540"
        "3:0 540 960 540"
        "4:960 540 960 540"
    )

    local entry
    for entry in "${cases[@]}"; do
        local slot="${entry%%:*}"
        local expected="${entry##*:}"

        local actual
        actual=$(compute_slot_geometry "$slot" quad 1920 1080)
        if [[ "$actual" != "$expected" ]]; then
            _fail "T3.4.$slot" "expected '$expected', got '$actual'"
            test_failed=1
        fi
    done

    if (( test_failed == 0 )); then
        _pass "T3.4 — quad mode 1920×1080: all 4 slots correct"
    fi
}

# =============================================================================
# Test T3.5 — compute_slot_geometry, quad mode, 1280×800 (Steam Deck)
# =============================================================================
test_t3_5() {
    local test_failed=0

    local cases=(
        "1:0 0 640 400"
        "2:640 0 640 400"
        "3:0 400 640 400"
        "4:640 400 640 400"
    )

    local entry
    for entry in "${cases[@]}"; do
        local slot="${entry%%:*}"
        local expected="${entry##*:}"

        local actual
        actual=$(compute_slot_geometry "$slot" quad 1280 800)
        if [[ "$actual" != "$expected" ]]; then
            _fail "T3.5.$slot" "expected '$expected', got '$actual'"
            test_failed=1
        fi
    done

    if (( test_failed == 0 )); then
        _pass "T3.5 — quad mode 1280×800: all 4 slots correct"
    fi
}

# =============================================================================
# Test T3.6 — odd resolution truncates (not rounds)
# =============================================================================
test_t3_6() {
    # 1366×768: half of 1366 = 683, half of 768 = 384
    local result
    result=$(compute_slot_geometry 4 quad 1366 768)
    if [[ "$result" == "683 384 683 384" ]]; then
        _pass "T3.6 — odd resolution truncates: 683 384 683 384"
    else
        _fail "T3.6" "expected '683 384 683 384', got '$result'"
    fi
}

# =============================================================================
# Test T3.7 — compute_grid_mode rejects invalid input
# =============================================================================
test_t3_7() {
    # Empty string should output "full" (documented behavior)
    local result
    result=$(compute_grid_mode "")
    if [[ "$result" == "full" ]]; then
        _pass "T3.7 — empty input returns 'full'"
    else
        _fail "T3.7" "expected 'full' for empty input, got '$result'"
    fi
}

# =============================================================================
# Test T3.8 — active slots \"1 2\" switching to \"1\" triggers grid mode change
# =============================================================================
test_t3_8() {
    local mode_before
    mode_before=$(compute_grid_mode "1 2")
    local mode_after
    mode_after=$(compute_grid_mode "1")

    if [[ "$mode_before" == "half" && "$mode_after" == "full" ]]; then
        _pass "T3.8 — slots 1,2→1 changes grid from half to full"
    else
        _fail "T3.8" "expected half→full, got ${mode_before}→${mode_after}"
    fi
}

# =============================================================================
# Test T3.9 — slot 3 only → quad mode, correct geometry
# =============================================================================
test_t3_9() {
    local grid
    grid=$(compute_grid_mode "3")
    if [[ "$grid" != "quad" ]]; then
        _fail "T3.9" "slot 3 only: expected grid 'quad', got '$grid'"
        return
    fi

    local geometry
    geometry=$(compute_slot_geometry 3 quad 1920 1080)
    if [[ "$geometry" == "0 540 960 540" ]]; then
        _pass "T3.9 — slot 3 only → quad, geometry 0 540 960 540"
    else
        _fail "T3.9" "expected '0 540 960 540', got '$geometry'"
    fi
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== window_manager test suite ==="
echo ""

test_t3_1
test_t3_2
test_t3_3
test_t3_4
test_t3_5
test_t3_6
test_t3_7
test_t3_8
test_t3_9

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
