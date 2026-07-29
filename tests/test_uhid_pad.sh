#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: tests/lib/uhid_pad.py (pure computation only)
# =============================================================================
# Covers the parts of the virtual-pad primitive that produce BYTES — the HID
# report descriptor, report encoding, the command-spec parser, and the packed
# uhid event sizes. No /dev/uhid, no root, no hardware: everything here runs
# identically in CI and on the Deck, which is the point. #136 / build plan #157.
#
# The device half (UhidPad.create/send/close) is deliberately NOT covered here
# — it needs real hardware and is validated by
# tests/probe-uhid-feasibility.sh on the Deck.
#
# Run: bash tests/test_uhid_pad.sh
# =============================================================================

readonly TEST_TOTAL=18

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Invoked through python3 rather than as an executable: the mode bit surviving
# a checkout is not something this suite should depend on, and an exec failure
# would otherwise masquerade as a validation pass in _expect_error.
readonly PAD_PY="$REPO_ROOT/tests/lib/uhid_pad.py"
_pad() { python3 "$PAD_PY" "$@"; }

# The expected descriptor, spelled out rather than recomputed. If someone edits
# build_report_descriptor(), this suite must go red — a test that regenerates
# the value it is checking would certify nothing (PRINCIPLES #4).
readonly EXPECTED_DESCRIPTOR="05010905a101a10005091901290c150025017501950c810275049501810305010930093109330934150026ff00750895048102c0c0"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() { echo "[PASS] $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
_fail() { echo "[FAIL] $1 — $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# _selftest_field: read one `key=value` line out of --self-test.
_selftest_field() {
    local key="$1"
    _pad --self-test | grep "^${key}=" | cut -d= -f2-
}

_expect() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$name"
    else
        _fail "$name" "expected '$expected', got '$actual'"
    fi
}

# _expect_error: the command must fail AND the message must mention $2. The
# substring match is the whole point — an earlier draft of this helper accepted
# any non-zero exit and went green on "permission denied", certifying nothing
# about the validation it claimed to cover.
_expect_error() {
    local name="$1" needle="$2"; shift 2
    local out rc=0
    out=$(_pad "$@" 2>&1) || rc=$?
    if (( rc == 0 )); then
        _fail "$name" "expected failure, but it succeeded with '$out'"
    elif [[ "$out" != *"$needle"* ]]; then
        _fail "$name" "expected a message mentioning '$needle', got '$out'"
    else
        _pass "$name"
    fi
}

# --- T1: packed struct sizes -------------------------------------------------
# 4376 = sizeof(struct uhid_event) = 4 (type) + 4372 (uhid_create2_req, the
# largest union member). If the kernel uapi ever grows a bigger member this
# number changes and every write becomes short — worth failing loudly on.

test_event_size()   { _expect "T1.1 sizeof(uhid_event) is 4376" \
                          "$(_selftest_field event_size)" "4376"; }
test_create2_size() { _expect "T1.2 CREATE2 event fills the struct" \
                          "$(_selftest_field create2_event_size)" "4376"; }
test_input2_size()  { _expect "T1.3 INPUT2 event fills the struct" \
                          "$(_selftest_field input2_event_size)" "4376"; }

# --- T2: report descriptor ---------------------------------------------------

test_descriptor_len() { _expect "T2.1 descriptor is 53 bytes" \
                            "$(_selftest_field descriptor_len)" "53"; }
test_descriptor_hex() { _expect "T2.2 descriptor bytes are exact" \
                            "$(_selftest_field descriptor_hex)" "$EXPECTED_DESCRIPTOR"; }
test_descriptor_cli() { _expect "T2.3 --emit-descriptor agrees with --self-test" \
                            "$(_pad --emit-descriptor)" "$EXPECTED_DESCRIPTOR"; }

# T2.4: Usage(Gamepad) is load-bearing — it is what makes hid-input map button 1
# to BTN_SOUTH (0x130), the bit _has_gamepad_buttons gates on. Usage(Joystick)
# would be 0x09 0x04 and map to BTN_JOYSTICK instead.
test_descriptor_gamepad_usage() {
    # bytes 0-5: 05 01 (Usage Page Generic Desktop) 09 05 (Usage Gamepad)
    #            a1 01 (Collection Application)
    # Slice the EMITTED descriptor, not EXPECTED_DESCRIPTOR — slicing the
    # constant would compare a literal against a literal and could never go red.
    local emitted head
    emitted="$(_pad --emit-descriptor)"
    head="${emitted:0:12}"
    _expect "T2.4 declares Usage(Gamepad), not Joystick" "$head" "05010905a101"
}

# --- T3: report encoding -----------------------------------------------------
# Layout: [buttons 1-8][buttons 9-12 + 4 pad][LX][LY][RX][RY], axes neutral 0x80.

test_report_len()     { _expect "T3.1 report is 6 bytes" \
                            "$(_selftest_field report_len)" "6"; }
test_report_neutral() { _expect "T3.2 neutral report has no bits, axes centred" \
                            "$(_selftest_field report_neutral)" "000080808080"; }
test_report_south()   { _expect "T3.3 BTN_SOUTH is bit 0 of byte 0" \
                            "$(_selftest_field report_south)" "010080808080"; }
test_report_start()   { _expect "T3.4 BTN_START (12) is bit 3 of byte 1" \
                            "$(_selftest_field report_start)" "000880808080"; }
test_report_combined() { _expect "T3.5 two buttons + an axis coexist" \
                            "$(_selftest_field report_south_start_lx200)" "0108c8808080"; }
# NB: SOUTH only — the self-test's report_south_start_lx200 also holds START, so
# this deliberately encodes a different report and asserts its own value.
test_encode_cli()     { _expect "T3.6 --encode-report encodes one button + axis" \
                            "$(_pad --encode-report 'BTN_SOUTH=1,LX=200')" \
                            "0100c8808080" ; }

# --- T4: spec parsing --------------------------------------------------------

test_spec_pressed() { _expect "T4.1 spec parses a pressed button" \
                          "$(_selftest_field spec_pressed)" "BTN_SOUTH"; }
test_spec_axes()    { _expect "T4.2 spec parses an axis value" \
                          "$(_selftest_field spec_axes)" "LX=200"; }

# --- T5: input validation (must fail loudly) ---------------------------------

test_reject_unknown_button() {
    _expect_error "T5.1 unknown button rejected" "unknown button" \
        --encode-report "BTN_NOPE=1"
}
test_reject_axis_range() {
    _expect_error "T5.2 out-of-range axis rejected" "out of range" \
        --encode-report "LX=999"
}
test_reject_button_value() {
    _expect_error "T5.3 non-boolean button value rejected" "takes 0 or 1" \
        --encode-report "BTN_SOUTH=7"
}

run_all_tests() {
    echo "=== uhid_pad.py (pure) ==="
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found — cannot run" >&2
        exit 1
    fi
    test_event_size
    test_create2_size
    test_input2_size
    test_descriptor_len
    test_descriptor_hex
    test_descriptor_cli
    test_descriptor_gamepad_usage
    test_report_len
    test_report_neutral
    test_report_south
    test_report_start
    test_report_combined
    test_encode_cli
    test_spec_pressed
    test_spec_axes
    test_reject_unknown_button
    test_reject_axis_range
    test_reject_button_value
    echo ""
    echo "$TESTS_PASSED/$TEST_TOTAL tests passed."
    if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
        exit 0
    else
        exit 1
    fi
}

run_all_tests
