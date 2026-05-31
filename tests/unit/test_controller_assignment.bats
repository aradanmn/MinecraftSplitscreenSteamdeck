#!/usr/bin/env bats
# =============================================================================
# Unit tests: controller-to-instance assignment
# Tests the assignControllerToSlot() logic and config file writing.
# =============================================================================

load "../helpers"

setup() {
    setup_test_env
    source_launcher_functions
}

teardown() {
    teardown_test_env
}

# ---------------------------------------------------------------------------
# getControllerSerial
# ---------------------------------------------------------------------------

@test "getControllerSerial returns unique MAC per device" {
    local s0 s1 s2 s3
    s0=$(getControllerSerial "$TEST_ROOT/dev/input/event0")
    s1=$(getControllerSerial "$TEST_ROOT/dev/input/event1")
    s2=$(getControllerSerial "$TEST_ROOT/dev/input/event2")
    s3=$(getControllerSerial "$TEST_ROOT/dev/input/event3")

    # All four serials should be non-empty
    [[ -n "$s0" && -n "$s1" && -n "$s2" && -n "$s3" ]]

    # All four serials should be distinct
    local unique_count
    unique_count=$(printf '%s\n' "$s0" "$s1" "$s2" "$s3" | sort -u | wc -l)
    [[ "$unique_count" -eq 4 ]]
}

@test "getControllerSerial returns empty string for unknown device" {
    local serial
    serial=$(getControllerSerial "$TEST_ROOT/dev/input/event99")
    [[ -z "$serial" ]]
}

# ---------------------------------------------------------------------------
# setControllableAutoSelect
# ---------------------------------------------------------------------------

@test "setControllableAutoSelect writes false to slot 1 toml" {
    local toml="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controllable-client.toml"
    printf '[controller]\n\tautoSelect = true\n' > "$toml"

    setControllableAutoSelect 1 false

    assert_file_contains "$toml" "autoSelect = false"
}

@test "setControllableAutoSelect writes true to slot 2 toml" {
    local toml="$INSTANCES_DIR/latestUpdate-2/.minecraft/config/controllable-client.toml"
    printf '[controller]\n\tautoSelect = false\n' > "$toml"

    setControllableAutoSelect 2 true

    assert_file_contains "$toml" "autoSelect = true"
}

@test "setControllableAutoSelect is a no-op when toml missing" {
    rm -f "$INSTANCES_DIR/latestUpdate-3/.minecraft/config/controllable-client.toml"
    # Should not error
    run setControllableAutoSelect 3 false
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# writeControllableConfigBySerial — Desktop Mode (no Steam Virtual Gamepad)
# ---------------------------------------------------------------------------

@test "writeControllableConfigBySerial sets autoSelect=true when no serial found" {
    # event99 has no sysfs entry → no serial
    local toml="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controllable-client.toml"
    printf '[controller]\n\tautoSelect = false\n' > "$toml"

    writeControllableConfigBySerial 1 "$TEST_ROOT/dev/input/event99"

    assert_file_contains "$toml" "autoSelect = true"
}

@test "writeControllableConfigBySerial sets autoSelect=true when no saved config exists" {
    # event0 has a serial but no pre-existing selected_controllers.json for it
    local toml="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controllable-client.toml"
    printf '[controller]\n\tautoSelect = false\n' > "$toml"

    writeControllableConfigBySerial 1 "$TEST_ROOT/dev/input/event0"

    assert_file_contains "$toml" "autoSelect = true"
}

@test "writeControllableConfigBySerial copies saved config and disables autoSelect" {
    # Plant a fake saved_controllers.json in slot 2 matching event0's serial
    local serial
    serial=$(getControllerSerial "$TEST_ROOT/dev/input/event0")
    local saved="$INSTANCES_DIR/latestUpdate-2/.minecraft/config/controllable/selected_controllers.json"
    printf '{"serial":"%s","guid":"abc123"}' "$serial" > "$saved"

    local toml="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controllable-client.toml"
    printf '[controller]\n\tautoSelect = true\n' > "$toml"
    local dest="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controllable/selected_controllers.json"

    writeControllableConfigBySerial 1 "$TEST_ROOT/dev/input/event0"

    # Config should be copied to slot 1
    assert_file_contains "$dest" "$serial"
    # autoSelect should be false
    assert_file_contains "$toml" "autoSelect = false"
}

# ---------------------------------------------------------------------------
# assignControllerToSlot — Desktop Mode sequential assignment
# ---------------------------------------------------------------------------

@test "assignControllerToSlot assigns different devices to each slot" {
    assignControllerToSlot 1
    INSTANCE_ACTIVE[0]=1

    assignControllerToSlot 2
    INSTANCE_ACTIVE[1]=1

    assignControllerToSlot 3
    INSTANCE_ACTIVE[2]=1

    assignControllerToSlot 4

    local d0="${INSTANCE_CONTROLLER_DEVICE[0]}"
    local d1="${INSTANCE_CONTROLLER_DEVICE[1]}"
    local d2="${INSTANCE_CONTROLLER_DEVICE[2]}"
    local d3="${INSTANCE_CONTROLLER_DEVICE[3]}"

    # All four should be non-empty
    [[ -n "$d0" && -n "$d1" && -n "$d2" && -n "$d3" ]]

    # All four should be distinct
    local unique_count
    unique_count=$(printf '%s\n' "$d0" "$d1" "$d2" "$d3" | sort -u | wc -l)
    [[ "$unique_count" -eq 4 ]]
}

@test "assignControllerToSlot does not reuse a device assigned to an active slot" {
    INSTANCE_CONTROLLER_DEVICE[0]="$TEST_ROOT/dev/input/event0"
    INSTANCE_ACTIVE[0]=1

    assignControllerToSlot 2

    local d1="${INSTANCE_CONTROLLER_DEVICE[1]}"
    [[ "$d1" != "$TEST_ROOT/dev/input/event0" ]]
}
