#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: controller_monitor.sh
# =============================================================================
# All tests use mocked /proc/bus/input/devices files and mock udevadm.
# No hardware, root, or Steam client required.
# Run: bash tests/test_controller_monitor.sh
# =============================================================================

readonly TEST_TOTAL=9

# Find the repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/modules/controller_monitor.sh"

TESTS_PASSED=0
TESTS_FAILED=0

# --- Helpers ---

_assert_equals() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        echo "  expected: $expected" >&2
        echo "  got:      $actual" >&2
        return 1
    fi
}

_pass() {
    echo "[PASS] $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_fail() {
    echo "[FAIL] $1 — $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Helper: count lines in output
_count_lines() {
    local count=0
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        count=$((count + 1))
    done <<< "$1"
    echo "$count"
}

# =============================================================================
# Test T2.1 — parse_proc_input_devices: single 28de:11ff block
# =============================================================================
test_t2_1() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29 js1

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _parse_steam_virtual_devices)

    if _assert_equals "$result" "29 1" "T2.1"; then
        _pass "T2.1 — single 28de:11ff block parsed: event29 js1"
    else
        _fail "T2.1" "expected '29 1', got '$result'"
    fi
}

# =============================================================================
# Test T2.2 — parse_proc_input_devices: two 28de:11ff blocks
# =============================================================================
test_t2_2() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input653
U: Uniq=
H: Handlers=event30 js2

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _parse_steam_virtual_devices)

    local count
    count=$(_count_lines "$result")

    if (( count == 2 )); then
        local line1 line2
        line1=$(echo "$result" | sed -n '1p')
        line2=$(echo "$result" | sed -n '2p')
        if _assert_equals "$line1" "29 1" "T2.2a" && _assert_equals "$line2" "30 2" "T2.2b"; then
            _pass "T2.2 — two 28de:11ff blocks parsed"
        else
            _fail "T2.2" "expected '29 1' and '30 2', got '$line1' and '$line2'"
        fi
    else
        _fail "T2.2" "expected 2 lines, got $count"
    fi
}

# =============================================================================
# Test T2.3 — parse_proc_input_devices: mixed devices, only 28de:11ff extracted
# =============================================================================
test_t2_3() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=054c Product=09cc Version=0111
N: Name="Sony Interactive Entertainment DualSense Wireless Controller"
P: Phys=usb-0000:00:14.0-1/input0
S: Sysfs=/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/input/input650
U: Uniq=
H: Handlers=event28 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29 js1

I: Bus=0003 Vendor=28de Product=0394 Version=0001
N: Name="Steam Controller"
P: Phys=
S: Sysfs=/devices/virtual/input/input653
U: Uniq=
H: Handlers=event30 js2

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _parse_steam_virtual_devices)

    local count
    count=$(_count_lines "$result")

    if (( count == 1 )); then
        if _assert_equals "$result" "29 1" "T2.3"; then
            _pass "T2.3 — only 28de:11ff extracted from mixed devices"
        else
            _fail "T2.3" "expected '29 1', got '$result'"
        fi
    else
        _fail "T2.3" "expected 1 line (only 28de:11ff), got $count lines: $result"
    fi
}

# =============================================================================
# Test T2.4 — parse_proc_input_devices: Handlers line with only eventN (no js)
# =============================================================================
test_t2_4() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event29

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _parse_steam_virtual_devices)

    if [[ -z "$result" ]]; then
        _pass "T2.4 — device without jsN correctly skipped"
    else
        _fail "T2.4" "expected no output for device without jsN, got '$result'"
    fi
}

# =============================================================================
# Test T2.5 — list_eligible_controllers in docked mode, no D-Bus (fallback)
# =============================================================================
test_t2_5() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event4 js1

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)

    local count
    count=$(_count_lines "$result")

    if (( count == 1 )); then
        # Should be the second device (event4 js1) — first excluded as internal
        if [[ "$result" == "/dev/input/event4 /dev/input/js1 0000 0000" ]]; then
            _pass "T2.5 — docked mode fallback: second device selected, first excluded"
        else
            _fail "T2.5" "expected '/dev/input/event4 /dev/input/js1 0000 0000', got '$result'"
        fi
    else
        _fail "T2.5" "expected 1 eligible device, got $count: $result"
    fi
}

# =============================================================================
# Test T2.6 — list_eligible_controllers in handheld mode
# =============================================================================
test_t2_6() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event4 js1

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" list_eligible_controllers handheld)

    # Handheld mode: first gamepad-capable device (any VID:PID, lowest jsN)
    if [[ "$result" == "/dev/input/event3 /dev/input/js0 28de 11ff" ]]; then
        _pass "T2.6 — handheld mode: first device selected (event3 js0)"
    else
        _fail "T2.6" "expected '/dev/input/event3 /dev/input/js0 28de 11ff', got '$result'"
    fi
}

# =============================================================================
# Test T2.7 — list_eligible_controllers: more than 4 eligible devices capped at 4
# =============================================================================
test_t2_7() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event4 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input653
U: Uniq=
H: Handlers=event5 js2

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input654
U: Uniq=
H: Handlers=event6 js3

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input655
U: Uniq=
H: Handlers=event7 js4

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"  (6th virtual — internal + 5 external)
P: Phys=
S: Sysfs=/devices/virtual/input/input656
U: Uniq=
H: Handlers=event8 js5

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)

    local count
    count=$(_count_lines "$result")

    if (( count == 4 )); then
        # First 4 eligible (events 4,5,6,7 — event3 is internal)
        local line1
        line1=$(echo "$result" | sed -n '1p')
        if _assert_equals "$line1" "/dev/input/event4 /dev/input/js1 0000 0000" "T2.7"; then
            _pass "T2.7 — 5 eligible devices capped at 4"
        else
            _fail "T2.7" "expected event4/js1 as first, got '$line1'"
        fi
    else
        _fail "T2.7" "expected 4 devices (capped), got $count: $result"
    fi
}

# =============================================================================
# Test T2.8 — FIFO message format: CONTROLLER_ADD
# =============================================================================
test_t2_8() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Initial state: only internal gamepad (excluded in docked mode)
    cat > "$tmpdir/proc_input_initial" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

PROCEOF

    # After add: internal + physical DualSense + external virtual
    cat > "$tmpdir/proc_input_after" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0003 Vendor=054c Product=09cc Version=0111
N: Name="Sony DualSense"
P: Phys=usb-0000:00:14.0-1/input0
S: Sysfs=/devices/pci0000:00/usb1/1-1/1-1:1.0/input/input700
U: Uniq=
H: Handlers=event20 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event4 js2

PROCEOF

    local fifo="$tmpdir/splitscreen.fifo"
    mkfifo "$fifo"

    # Use polling fallback (non-existent udevadm path forces polling)
    INPUTPLUMBER_DBUS_AVAILABLE=0 \
        PROC_INPUT_DEVICES="$tmpdir/proc_input_initial" \
        CONTROLLER_MONITOR_UDEVADM_CMD="/nonexistent/udevadm_fake" \
        SPLITSCREEN_FIFO="$fifo" \
        start_controller_monitor docked &
    local monitor_pid=$!

    # Switch proc file before first poll (poll interval is 2s)
    sleep 0.3
    # Override PROC_INPUT_DEVICES for the already-running monitor? Can't.
    # Instead, use a symlink-based approach that the monitor reads.
    # Actually, the monitor already read the initial state. To inject a change,
    # we need the FIFO write to happen. Let's use the polling approach differently.
    #
    # Since we can't change PROC_INPUT_DEVICES of a running process, we need
    # to make the initial file include the new device FROM THE START,
    # but only AFTER a delay. Use a symlink that points to initial, then switch.
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    rm -f "$fifo"

    # --- Retry with symlink approach + polling ---
    ln -sf "$tmpdir/proc_input_initial" "$tmpdir/proc_input_link"

    mkfifo "$fifo"

    INPUTPLUMBER_DBUS_AVAILABLE=0 \
        PROC_INPUT_DEVICES="$tmpdir/proc_input_link" \
        CONTROLLER_MONITOR_UDEVADM_CMD="/nonexistent/udevadm_fake" \
        SPLITSCREEN_FIFO="$fifo" \
        start_controller_monitor docked &
    monitor_pid=$!

    # Initial poll happens at t~0s (initial snapshot), then sleep 2s, then re-poll.
    # Switch symlink after initial snapshot but before first re-poll.
    sleep 0.3
    ln -sf "$tmpdir/proc_input_after" "$tmpdir/proc_input_link"

    # Read from FIFO — should get CONTROLLER_ADD within ~3s (2s poll + processing)
    local line
    if read -r -t 8 line < "$fifo"; then
        if [[ "$line" == "CONTROLLER_ADD /dev/input/event4 /dev/input/js2 054c 09cc" ]]; then
            _pass "T2.8 — CONTROLLER_ADD message format correct"
        else
            _fail "T2.8" "expected 'CONTROLLER_ADD /dev/input/event4 /dev/input/js2 054c 09cc', got '$line'"
        fi
    else
        _fail "T2.8" "timed out waiting for CONTROLLER_ADD message"
    fi

    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# Test T2.9 — CONTROLLER_REMOVE message on device removal
# =============================================================================
test_t2_9() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # Initial state: 2 virtual devices (event3/internal, event4/external)
    cat > "$tmpdir/proc_input_initial" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input652
U: Uniq=
H: Handlers=event4 js1

PROCEOF

    # After removal: only internal remains
    cat > "$tmpdir/proc_input_after" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

PROCEOF

    ln -sf "$tmpdir/proc_input_initial" "$tmpdir/proc_input_link"

    local fifo="$tmpdir/splitscreen.fifo"
    mkfifo "$fifo"

    INPUTPLUMBER_DBUS_AVAILABLE=0 \
        PROC_INPUT_DEVICES="$tmpdir/proc_input_link" \
        CONTROLLER_MONITOR_UDEVADM_CMD="/nonexistent/udevadm_fake" \
        SPLITSCREEN_FIFO="$fifo" \
        start_controller_monitor docked &
    local monitor_pid=$!

    # Switch symlink after initial snapshot
    sleep 0.3
    ln -sf "$tmpdir/proc_input_after" "$tmpdir/proc_input_link"

    local line
    if read -r -t 8 line < "$fifo"; then
        if [[ "$line" == "CONTROLLER_REMOVE /dev/input/event4" ]]; then
            _pass "T2.9 — CONTROLLER_REMOVE message format correct"
        else
            _fail "T2.9" "expected 'CONTROLLER_REMOVE /dev/input/event4', got '$line'"
        fi
    else
        _fail "T2.9" "timed out waiting for CONTROLLER_REMOVE message"
    fi

    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# Run all tests
# =============================================================================
echo "=== controller_monitor test suite ==="
echo ""

test_t2_1
test_t2_2
test_t2_3
test_t2_4
test_t2_5
test_t2_6
test_t2_7
test_t2_8
test_t2_9

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
