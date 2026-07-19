#!/bin/bash
set -euo pipefail

# =============================================================================
# Test Suite: controller_monitor.sh
# =============================================================================
# All tests use mocked /proc/bus/input/devices files and mock udevadm.
# No hardware, root, or Steam client required.
# Run: bash tests/test_controller_monitor.sh
# =============================================================================

readonly TEST_TOTAL=21

# Find the repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/modules/controller_monitor.sh"
# #38 PR3: _find_slot_by_uniq (T2.21) is orchestrator.sh's, not this
# module's — sourcing it here only defines functions (no side effects at
# source time beyond runtime_context.sh, already sourced above).
source "$REPO_ROOT/modules/orchestrator.sh"

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

    # NOTE (pre-existing, unrelated to #38 PR3): this test's expectation
    # ("external claims a Steam-minted virtual") targets the LEGACY
    # virtual-mapper, but CONTROLLER_MONITOR_RAW_BINDING's runtime default
    # was promoted to 1 (raw) after this test was written and MCSS_RAW_BINDING
    # is readonly by the time this test runs (can't pin it back per-test
    # without a fresh interpreter) — this assertion already fails on main,
    # independent of PR3's uniq plumbing. Left as-is; not a PR3 regression.
    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        INPUTPLUMBER_DBUS_AVAILABLE=0 \
        list_eligible_controllers docked)

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

    # NOTE (pre-existing, unrelated to #38 PR3): see the T2.5 comment above
    # — this assertion already fails on main under the raw-binding default.
    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)

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
U: Uniq=dc:0c:2d:aa:bb:cc
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
    # #38 PR3: field 5 is phys_uniq, threaded from the DualSense block's
    # `U: Uniq=` line above. Default CONTROLLER_MONITOR_RAW_BINDING (unset ==
    # 1) means docked mode's source is _list_raw_external_pads, so the
    # eligible/added device is the DualSense's OWN raw node (event20 js1),
    # not the (unclaimed) X-Box-pad virtual — matches the raw-binding-is-
    # DEFAULT behavior documented at the top of this module.
    local line expected
    expected="CONTROLLER_ADD /dev/input/event20 /dev/input/js1 054c 09cc"
    expected="$expected dc:0c:2d:aa:bb:cc"
    if read -r -t 8 line < "$fifo"; then
        if [[ "$line" == "$expected" ]]; then
            _pass "T2.8 — CONTROLLER_ADD format correct (5 fields, uniq)"
        else
            _fail "T2.8" "expected '$expected', got '$line'"
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

    # NOTE (pre-existing, unrelated to #38 PR3): see the T2.5 comment above
    # — this assertion already fails on main under the raw-binding default.
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
    # NOTE (pre-existing, unrelated to #38 PR3): see the T2.5 comment above
    # — this assertion already fails on main under the raw-binding default.
    local result count
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)
    count=$(_count_lines "$result")
    if (( count == 0 )); then
        _pass "T2.11 — external present but virtual not ready: 0 players, no built-in leak"
    else
        _fail "T2.11" "expected 0 (await virtual), got $count: $result"
    fi
}

# =============================================================================
# Test T2.12 — #45 deprecation aliases mirror the MCSS-owned ids
# =============================================================================
test_t2_12() {
    # CONTROLLER_MONITOR_STEAM_VENDOR/PRODUCT survive one release as aliases for
    # external consumers; they must equal the runtime_context-owned values so a
    # consumer on either name sees the same Deck built-in exclusion.
    if [[ "$CONTROLLER_MONITOR_STEAM_VENDOR" == "$MCSS_STEAM_VENDOR_ID" \
       && "$CONTROLLER_MONITOR_STEAM_PRODUCT" == "$MCSS_STEAM_PRODUCT_ID" \
       && "$MCSS_STEAM_VENDOR_ID" == "28de" && "$MCSS_STEAM_PRODUCT_ID" == "11ff" ]]; then
        _pass "T2.12 — deprecation aliases mirror MCSS_STEAM_VENDOR_ID/PRODUCT_ID (28de:11ff)"
    else
        _fail "T2.12" "alias mismatch: alias=$CONTROLLER_MONITOR_STEAM_VENDOR:$CONTROLLER_MONITOR_STEAM_PRODUCT mcss=$MCSS_STEAM_VENDOR_ID:$MCSS_STEAM_PRODUCT_ID"
    fi
}

# =============================================================================
# #38 PR3 — uniq (field 8) plumbing tests
# =============================================================================

# =============================================================================
# Test T2.13 — parse_input_device_blocks: field 8 (uniq) captured; empty for
# a bare "U: Uniq=" line
# =============================================================================
test_t2_13() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=aa:bb:cc:dd:ee:ff
S: Sysfs=/devices/virtual/misc/uhid/X/input/input700
U: Uniq=11:22:33:44:55:66
H: Handlers=event10 js3

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad"
P: Phys=
S: Sysfs=/devices/virtual/input/input651
U: Uniq=
H: Handlers=event3 js0

PROCEOF
    local blocks line1 line2
    blocks=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" parse_input_device_blocks)
    line1=$(echo "$blocks" | sed -n '1p')
    line2=$(echo "$blocks" | sed -n '2p')

    local vendor product name handlers sysfs phys keybits uniq ok=1
    IFS=$'\x1f' read -r vendor product name handlers sysfs phys keybits \
        uniq <<< "$line1"
    [[ "$vendor" == "054c" && "$uniq" == "11:22:33:44:55:66" ]] || ok=0

    IFS=$'\x1f' read -r vendor product name handlers sysfs phys keybits \
        uniq <<< "$line2"
    [[ "$vendor" == "28de" && -z "$uniq" ]] || ok=0

    if (( ok )); then
        _pass "T2.13 — parse_input_device_blocks: field 8 uniq (real + empty)"
    else
        _fail "T2.13" "field-8 uniq mismatch: line1='$line1' line2='$line2'"
    fi
}

# =============================================================================
# Test T2.14 — _has_gamepad_buttons regression (read site #3): a pad block
# with a REAL "U: Uniq=" line AFTER "B: KEY=" still passes the
# _list_raw_external_pads capability gate (the 8-var read must keep keybits
# clean of the trailing uniq field — see the module's read-site table).
# =============================================================================
test_t2_14() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    # B: KEY= bitmap: 5 words, word[0]=0x1000000000000 → bit 48 set →
    # BTN_SOUTH (0x130=304, bit 48 of the bits-256..319 word) → gate ACCEPTS.
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=aa:bb:cc:dd:ee:ff
S: Sysfs=/devices/virtual/misc/uhid/REG/input/input800
B: KEY=1000000000000 0 0 0 0
U: Uniq=11:22:33:44:55:66
H: Handlers=event30 js5

PROCEOF
    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _list_raw_external_pads \
        2>/dev/null)
    if [[ "$result" == "30 5 054c 05c4 11:22:33:44:55:66" ]]; then
        _pass "T2.14 — gamepad-buttons gate passes with uniq (8-var read)"
    else
        local _msg="expected '30 5 054c 05c4 11:22:33:44:55:66'"
        _msg="$_msg, got '$result'"
        _fail "T2.14" "$_msg"
    fi
}

# =============================================================================
# Test T2.15 — _list_raw_external_pads emits a 5-field line with the
# correct uniq threaded through
# =============================================================================
test_t2_15() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/0005:054C:05C4.000A/input/input660
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event4 js1

PROCEOF
    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _list_raw_external_pads \
        2>/dev/null)
    if [[ "$result" == "4 1 054c 05c4 a0:5a:5e:d0:8a:dc" ]]; then
        _pass "T2.15 — _list_raw_external_pads: 5-field line, uniq threaded"
    else
        local _msg="expected '4 1 054c 05c4 a0:5a:5e:d0:8a:dc'"
        _msg="$_msg, got '$result'"
        _fail "T2.15" "$_msg"
    fi
}

# =============================================================================
# Test T2.16 — two same-MAC DS4s (identical U:, distinct event/js) → two
# distinct 5-field lines, BOTH carrying the shared MAC (never collapsed)
# =============================================================================
test_t2_16() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/AAAA/input/input660
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event4 js1

I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/BBBB/input/input670
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event6 js2

PROCEOF
    local result count
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _list_raw_external_pads \
        2>/dev/null)
    count=$(_count_lines "$result")
    local line1 line2
    line1=$(echo "$result" | sed -n '1p')
    line2=$(echo "$result" | sed -n '2p')
    if (( count == 2 )) \
        && [[ "$line1" == "4 1 054c 05c4 a0:5a:5e:d0:8a:dc" ]] \
        && [[ "$line2" == "6 2 054c 05c4 a0:5a:5e:d0:8a:dc" ]]; then
        _pass "T2.16 — two same-MAC DS4s: two lines, both carry the MAC"
    else
        _fail "T2.16" "expected 2 MAC-bearing lines, got $count: $result"
    fi
}

# =============================================================================
# Test T2.17 — empty-uniq pad → empty 5th field (no bare trailing space:
# a 4-token line, same as pre-PR3 — see the conditional-emit note in
# _list_raw_external_pads)
# =============================================================================
test_t2_17() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=
S: Sysfs=/devices/virtual/misc/uhid/CCCC/input/input680
U: Uniq=
H: Handlers=event7 js3

PROCEOF
    local result
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" _list_raw_external_pads \
        2>/dev/null)
    local uq
    read -r _ _ _ _ uq <<< "$result"
    if [[ "$result" == "7 3 054c 05c4" && -z "$uq" ]]; then
        _pass "T2.17 — empty-uniq pad: empty 5th field, no trailing space"
    else
        _fail "T2.17" "expected '7 3 054c 05c4' with empty 5th, got '$result'"
    fi
}

# =============================================================================
# Test T2.18 — start_controller_monitor's INITIAL-emit site (the second of
# the two #38 PR3 CONTROLLER_ADD emit sites) also carries the 5-field
# format with uniq
# =============================================================================
test_t2_18() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/0005:054C:05C4.000A/input/input660
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event4 js1

PROCEOF
    local fifo="$tmpdir/splitscreen.fifo"
    mkfifo "$fifo"

    # Default CONTROLLER_MONITOR_SKIP_INITIAL_EMIT (unset/0): the already-
    # connected pad above is emitted as a CONTROLLER_ADD from the INITIAL
    # snapshot (not the udev/poll loop) — this is the OTHER emit site.
    INPUTPLUMBER_DBUS_AVAILABLE=0 \
        PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        CONTROLLER_MONITOR_UDEVADM_CMD="/nonexistent/udevadm_fake" \
        SPLITSCREEN_FIFO="$fifo" \
        start_controller_monitor docked &
    local monitor_pid=$!

    local line expected
    expected="CONTROLLER_ADD /dev/input/event4 /dev/input/js1 054c 05c4"
    expected="$expected a0:5a:5e:d0:8a:dc"
    if read -r -t 8 line < "$fifo"; then
        if [[ "$line" == "$expected" ]]; then
            _pass "T2.18 — initial-emit CONTROLLER_ADD also carries 5 fields"
        else
            _fail "T2.18" "expected '$expected', got '$line'"
        fi
    else
        _fail "T2.18" "timed out waiting for initial CONTROLLER_ADD"
    fi

    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    rm -f "$fifo"
}

# =============================================================================
# Test T2.19 — _map_external_player_virtuals emits an empty 5th field (never
# populated — DO NOT key on uniq); byte-identical to its pre-PR3 4-field line
# =============================================================================
test_t2_19() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
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
    result=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        _map_external_player_virtuals 2>/dev/null)
    local uq
    read -r _ _ _ _ uq <<< "$result"
    # DS4's real MAC uniq is in the fixture, but this path NEVER surfaces it
    # (DO-NOT-key-on-uniq) — field 5 must read empty regardless, and the
    # line itself stays the exact pre-PR3 4-token shape.
    if [[ "$result" == "5 2 054c 05c4" && -z "$uq" ]]; then
        _pass "T2.19 — _map_external_player_virtuals: empty 5th (inert)"
    else
        _fail "T2.19" "expected '5 2 054c 05c4' empty 5th, got '$result'"
    fi
}

# =============================================================================
# Test T2.20 — list_eligible_controllers: docked passes uniq through
# (raw-binding default source); handheld's 5th field is always empty
# =============================================================================
test_t2_20() {
    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    cat > "$tmpdir/proc_input" <<'PROCEOF'
I: Bus=0005 Vendor=054c Product=05c4 Version=8111
N: Name="Wireless Controller"
P: Phys=a0:5a:5e:d0:8a:dc
S: Sysfs=/devices/virtual/misc/uhid/0005:054C:05C4.000A/input/input660
U: Uniq=a0:5a:5e:d0:8a:dc
H: Handlers=event4 js1

PROCEOF
    local docked docked_expected handheld ok=1
    docked=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        INPUTPLUMBER_DBUS_AVAILABLE=0 list_eligible_controllers docked)
    docked_expected="/dev/input/event4 /dev/input/js1 054c 05c4"
    docked_expected="$docked_expected a0:5a:5e:d0:8a:dc"
    [[ "$docked" == "$docked_expected" ]] || ok=0

    handheld=$(PROC_INPUT_DEVICES="$tmpdir/proc_input" \
        list_eligible_controllers handheld)
    local uq
    read -r _ _ _ _ uq <<< "$handheld"
    [[ "$handheld" == "/dev/input/event4 /dev/input/js1 054c 05c4" \
        && -z "$uq" ]] || ok=0

    if (( ok )); then
        _pass "T2.20 — docked passthrough + handheld empty uniq"
    else
        _fail "T2.20" "docked='$docked' handheld='$handheld'"
    fi
}

# =============================================================================
# Test T2.21 — _find_slot_by_uniq (orchestrator.sh, #38 PR3 — defined,
# unused): matches an active slot's phys_uniq; empty uniq NEVER matches
# (D2 clone-pad guard); an unmatched MAC returns empty.
# =============================================================================
test_t2_21() {
    # Fixture PIDs MUST exceed kernel.pid_max — see test_orchestrator.sh's
    # constants+guard: teardown-style consumers of this same state-file
    # shape do process-group kills keyed on these fields, so a reachable
    # value could hit a REAL process group in an un-namespaced run.
    local pid_max fixture_pid
    pid_max=$(cat /proc/sys/kernel/pid_max)
    fixture_pid=$(( pid_max + 100000 ))

    local tmpdir; tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' RETURN
    export SPLITSCREEN_STATE="$tmpdir/splitscreen_state.json"
    cat > "$SPLITSCREEN_STATE" <<EOF
{
  "mode": "docked",
  "slots": {
    "1": {"active": true, "bwrap_pid": $fixture_pid,
           "phys_uniq": "a0:5a:5e:d0:8a:dc"},
    "2": {"active": true, "bwrap_pid": $fixture_pid, "phys_uniq": ""}
  }
}
EOF
    local matched empty_guard unmatched ok=1
    matched=$(_find_slot_by_uniq "a0:5a:5e:d0:8a:dc")
    [[ "$matched" == "1" ]] || ok=0

    empty_guard=$(_find_slot_by_uniq "")
    [[ -z "$empty_guard" ]] || ok=0

    unmatched=$(_find_slot_by_uniq "ff:ff:ff:ff:ff:ff")
    [[ -z "$unmatched" ]] || ok=0

    if (( ok )); then
        _pass "T2.21 — _find_slot_by_uniq: match / empty-guard / unmatched"
    else
        local _msg="matched='$matched' empty_guard='$empty_guard'"
        _msg="$_msg unmatched='$unmatched'"
        _fail "T2.21" "$_msg"
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
test_t2_12
test_t2_13
test_t2_14
test_t2_15
test_t2_16
test_t2_17
test_t2_18
test_t2_19
test_t2_20
test_t2_21

echo ""
echo "$TESTS_PASSED/$TEST_TOTAL tests passed."

if (( TESTS_FAILED == 0 && TESTS_PASSED == TEST_TOTAL )); then
    exit 0
else
    exit 1
fi
