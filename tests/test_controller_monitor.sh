#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: controller_monitor.sh
# =============================================================================
# All tests use mocked /proc/bus/input/devices files and mock udevadm.
# No hardware, root, or Steam client required.
# Run: bash tests/test_controller_monitor.sh
# =============================================================================

readonly TEST_TOTAL=11

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

    # Built-in's virtual (oldest inputN, NO external behind it) + one real external DS4
    # (raw 054c:05c4 + the 28de:11ff virtual Steam mints right after it, higher inputN).
    # Positive-ID must claim the DS4's virtual and leave the built-in's unclaimed (no leak).
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/0005:054C:05C4.000A/input/input660
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event4 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 1"
P: Phys=
S: Sysfs=/devices/virtual/input/input661
U: Uniq=
H: Handlers=event5 js2

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)

    local count
    count=$(_count_lines "$result")

    if (( count == 1 )); then
        # The DS4's virtual (event5 js2), tagged with the DS4's real VID:PID; the
        # built-in's virtual (event3) is correctly excluded.
        if [[ "$result" == "/dev/input/event5 /dev/input/js2 054c 05c4" ]]; then
            _pass "T2.5 — docked: external mapped to its virtual, built-in excluded"
        else
            _fail "T2.5" "expected '/dev/input/event5 /dev/input/js2 054c 05c4', got '$result'"
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

    # Built-in's virtual (input651) + FIVE real external DS4s, each = raw 054c:05c4 +
    # its 28de:11ff virtual born right after (higher inputN). 5 external players must be
    # capped at MAX_PLAYERS=4; the built-in's virtual is never a player.
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller 1"
S: Sysfs=/devices/virtual/misc/uhid/A/input/input660
H: Handlers=event10 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 1"
S: Sysfs=/devices/virtual/input/input661
H: Handlers=event11 js2

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller 2"
S: Sysfs=/devices/virtual/misc/uhid/B/input/input670
H: Handlers=event12 js3

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 2"
S: Sysfs=/devices/virtual/input/input671
H: Handlers=event13 js4

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller 3"
S: Sysfs=/devices/virtual/misc/uhid/C/input/input680
H: Handlers=event14 js5

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 3"
S: Sysfs=/devices/virtual/input/input681
H: Handlers=event15 js6

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller 4"
S: Sysfs=/devices/virtual/misc/uhid/D/input/input690
H: Handlers=event16 js7

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 4"
S: Sysfs=/devices/virtual/input/input691
H: Handlers=event17 js8

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller 5"
S: Sysfs=/devices/virtual/misc/uhid/E/input/input700
H: Handlers=event18 js9

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 5"
S: Sysfs=/devices/virtual/input/input701
H: Handlers=event19 js10

PROCEOF

    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)

    local count
    count=$(_count_lines "$result")

    if (( count == 4 )); then
        # First external (lowest inputN, input660) claims its virtual event11/js2.
        local line1
        line1=$(echo "$result" | sed -n '1p')
        if _assert_equals "$line1" "/dev/input/event11 /dev/input/js2 054c 05c4" "T2.7"; then
            _pass "T2.7 — 5 external players capped at 4 (built-in never a player)"
        else
            _fail "T2.7" "expected event11/js2 as first, got '$line1'"
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
S: Sysfs=/devices/virtual/input/input701
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

    # Initial state: built-in virtual (event3) + one real external DS4 (raw input700 +
    # its virtual event4 at input701, born after the raw). Eligible = the external's
    # virtual (event4). After removal both the raw and its virtual vanish.
    cat > "$tmpdir/proc_input_initial" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
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
N: Name="Microsoft X-Box 360 pad 1"
P: Phys=
S: Sysfs=/devices/virtual/input/input701
U: Uniq=
H: Handlers=event4 js2

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
        CONTROLLER_MONITOR_SKIP_INITIAL_EMIT=1 \
        start_controller_monitor docked &
    local monitor_pid=$!

    # Switch symlink after initial snapshot. SKIP_INITIAL_EMIT=1 (as docked_flow uses)
    # baselines the already-present external WITHOUT emitting an ADD, so the only FIFO
    # message is the REMOVE when the external disappears.
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
# Test T2.10 — startup phantom pool (virtuals with no external) → 0 players
# =============================================================================
test_t2_10() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    # Steam pre-creates a POOL of 28de:11ff virtuals at startup (built-in + phantoms)
    # with NO external pad behind any of them. None must become a player. This is the
    # exact case the old "exclude one, keep the rest" heuristic turned into ghost players.
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
S: Sysfs=/devices/virtual/input/input651
H: Handlers=event3 js0

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 1"
S: Sysfs=/devices/virtual/input/input652
H: Handlers=event4 js1

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 2"
S: Sysfs=/devices/virtual/input/input653
H: Handlers=event5 js2

PROCEOF
    local result count
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)
    count=$(_count_lines "$result")
    if (( count == 0 )); then
        _pass "T2.10 — startup phantom pool (no external) yields 0 players"
    else
        _fail "T2.10" "expected 0 players for phantom-only pool, got $count: $result"
    fi
}

# =============================================================================
# Test T2.11 — external present but its virtual not yet created → 0 (no built-in leak)
# =============================================================================
test_t2_11() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    # An external DS4 has connected (raw node present) but Steam has not yet minted its
    # 28de:11ff virtual. The built-in's virtual (lower inputN) must NOT be claimed for it;
    # the acquisition poll retries once the real virtual appears.
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
S: Sysfs=/devices/virtual/input/input651
H: Handlers=event3 js0

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
S: Sysfs=/devices/virtual/misc/uhid/A/input/input660
H: Handlers=event4 js1

PROCEOF
    local result count
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)
    count=$(_count_lines "$result")
    if (( count == 0 )); then
        _pass "T2.11 — external present but virtual not ready: 0 players, no built-in leak"
    else
        _fail "T2.11" "expected 0 (await virtual), got $count: $result"
    fi
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
test_t2_10
test_t2_11

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
