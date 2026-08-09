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

readonly TEST_TOTAL=23

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
# #70 v1.2: 15 buttons (adds MODE/Guide, THUMBL/THUMBR i.e. L3/R3), a Hat
# Switch (D-pad), and LT/RT analog trigger axes alongside the original 4
# stick axes — hand-verified byte-by-byte against the HID item stream before
# being pasted in here.
readonly EXPECTED_DESCRIPTOR="05010905a101a10005091901290f150025017501950f810275019501810305010939150025077504950181427504950181030501093009310933093409320935150026ff00750895068102c0c0"

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

test_descriptor_len() { _expect "T2.1 descriptor is 77 bytes" \
                            "$(_selftest_field descriptor_len)" "77"; }
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
# Layout: [buttons 1-8][buttons 9-13 + 3 pad][hat + 4 pad][LX][LY][RX][RY]
#         [LT][RT] — sticks neutral 0x80, hat released 0x08, triggers rest 0x00.

test_report_len()     { _expect "T3.1 report is 9 bytes" \
                            "$(_selftest_field report_len)" "9"; }
test_report_neutral() { _expect "T3.2 neutral report: no bits, hat released, sticks centred, triggers at rest" \
                            "$(_selftest_field report_neutral)" "000008808080800000"; }
test_report_south()   { _expect "T3.3 BTN_SOUTH is bit 0 of byte 0" \
                            "$(_selftest_field report_south)" "010008808080800000"; }
test_report_start()   { _expect "T3.4 BTN_START (12) is bit 3 of byte 1" \
                            "$(_selftest_field report_start)" "000808808080800000"; }
test_report_mode()    { _expect "T3.5 BTN_MODE (13, Guide/Home) is bit 4 of byte 1" \
                            "$(_selftest_field report_mode)" "001008808080800000"; }
test_report_thumbs()  { _expect "T3.6 BTN_THUMBL/BTN_THUMBR (14/15, L3/R3) are bits 5-6 of byte 1" \
                            "$(_selftest_field report_thumbs)" "006008808080800000"; }
test_report_combined() { _expect "T3.7 two buttons + an axis coexist" \
                            "$(_selftest_field report_south_start_lx200)" "010808c88080800000"; }
test_report_hat_up()  { _expect "T3.8 hat UP encodes as 0 in the hat nibble" \
                            "$(_selftest_field report_hat_up)" "000000808080800000"; }
test_report_trigger() { _expect "T3.9 LT/RT are independent trailing axes, sticks stay at rest" \
                            "$(_selftest_field report_trigger)" "00000880808080ff40"; }
# NB: SOUTH only — the self-test's report_south_start_lx200 also holds START, so
# this deliberately encodes a different report and asserts its own value.
test_encode_cli()     { _expect "T3.10 --encode-report encodes one button + axis" \
                            "$(_pad --encode-report 'BTN_SOUTH=1,LX=200')" \
                            "010008c88080800000" ; }

# --- T4: spec parsing --------------------------------------------------------

test_spec_pressed() { _expect "T4.1 spec parses a pressed button" \
                          "$(_selftest_field spec_pressed)" "BTN_SOUTH"; }
test_spec_axes()    { _expect "T4.2 spec parses an axis value" \
                          "$(_selftest_field spec_axes)" "LX=200"; }
test_spec_hat()      { _expect "T4.3 spec parses HAT=NE as direction 1" \
                          "$(_selftest_field spec_hat)" "1"; }

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
    test_report_mode
    test_report_thumbs
    test_report_combined
    test_report_hat_up
    test_report_trigger
    test_encode_cli
    test_spec_pressed
    test_spec_axes
    test_spec_hat
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
