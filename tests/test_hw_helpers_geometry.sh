#!/bin/bash
set -uo pipefail

# =============================================================================
# Test Suite: hw_expected_slot_geometry vs the product's layout rule (T9, #207)
# =============================================================================
# tests/hardware/lib/helpers.sh used to carry its own copy of the grid/cell
# policy ("mirrors compute_grid_mode"), and it had drifted: it said
# `any slot>=3 -> quad` and mapped half-mode cells by slot NUMBER, while the
# product (modules/window_manager.sh) is COUNT-based and maps half/full cells
# by the slot's ORDER among the active slots. Every current stage passes a
# contiguous set, so the divergence never showed; the first "P2 leaves,
# P1+P3 reflow" assertion would have failed on correct product behaviour.
#
# The helper now derives its answer from the product's own pure functions.
# This suite sweeps every non-empty subset of {1..4} x every slot in it and
# compares the helper to an oracle written from the apply_layout cell rule
# (quad -> cell = slot number; half/full -> cell = order among active).
# PRINCIPLES #9: one encoding, checked mechanically.
#
# No hardware. Run: bash tests/test_hw_helpers_geometry.sh
# =============================================================================

readonly TEST_TOTAL=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT

TESTS_PASSED=0
TESTS_FAILED=0
_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MCSS_WORKDIR="$TMP/workdir"
export HW_LOG="$TMP/hw.log"
export HW_PASSED=0 HW_FAILED=0 HW_SKIPPED=0

# shellcheck source=modules/window_manager.sh
source "$REPO_ROOT/modules/window_manager.sh"
# shellcheck source=tests/hardware/lib/helpers.sh
source "$REPO_ROOT/tests/hardware/lib/helpers.sh"

# _oracle SLOT ACTIVE SW SH: the product rule, spelled independently of the
# helper (compute_grid_mode + the apply_layout cell mapping + compute_slot_geometry).
_oracle() {
    local slot="$1" active="$2" sw="$3" sh="$4"
    local grid; grid=$(compute_grid_mode "$active")
    local cell=0 order=0 s
    for s in $active; do
        order=$(( order + 1 ))
        [[ "$s" == "$slot" ]] && { cell=$order; break; }
    done
    [[ "$grid" == "quad" ]] && cell="$slot"
    compute_slot_geometry "$cell" "$grid" "$sw" "$sh"
}

# --- T9.1: exhaustive sweep, 1920x1080 --------------------------------------
checked=0; divergent=0; first=""
for mask in $(seq 1 15); do
    active=""
    for s in 1 2 3 4; do (( mask & (1 << (s - 1)) )) && active+="$s "; done
    active="${active% }"
    for s in $active; do
        got=$(hw_expected_slot_geometry "$s" "$active" 1920 1080 2>/dev/null)
        want=$(_oracle "$s" "$active" 1920 1080)
        checked=$((checked + 1))
        if [[ "$got" != "$want" ]]; then
            divergent=$((divergent + 1))
            [[ -z "$first" ]] && first="active='$active' slot=$s helper='$got' product='$want'"
        fi
    done
done
if (( divergent == 0 && checked == 32 )); then
    _pass "T9.1 helper == product rule for all 32 (subset, slot) pairs at 1920x1080"
else
    _fail "T9.1 helper == product rule for all 32 (subset, slot) pairs at 1920x1080" \
        "checked=$checked divergent=$divergent first: $first"
fi

# --- T9.2: the case the old copy got wrong, spelled out ---------------------
got=$(hw_expected_slot_geometry 3 "1 3" 1920 1080 2>/dev/null)
if [[ "$got" == "0 540 1920 540" ]]; then
    _pass "T9.2 active {1,3}: slot 3 is the bottom HALF, not the bottom-left quarter"
else
    _fail "T9.2 active {1,3}: slot 3 is the bottom HALF, not the bottom-left quarter" "got '$got'"
fi

# --- T9.3: quad cells are stable by slot number, not order ------------------
got=$(hw_expected_slot_geometry 4 "1 3 4" 1920 1080 2>/dev/null)
if [[ "$got" == "960 540 960 540" ]]; then
    _pass "T9.3 active {1,3,4}: slot 4 keeps the lower-right quadrant"
else
    _fail "T9.3 active {1,3,4}: slot 4 keeps the lower-right quadrant" "got '$got'"
fi

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
fi
exit 1
