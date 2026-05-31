#!/usr/bin/env bats
# =============================================================================
# Unit tests: controller-to-instance assignment
# Tests the assignControllerToSlot() logic and Controlify config writing.
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
# writeControlifyConfig
# ---------------------------------------------------------------------------

@test "writeControlifyConfig writes lwjgl:0 for slot 1" {
    writeControlifyConfig 1 0

    local cfg="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controlify/controlify.json"
    assert_file_contains "$cfg" '"lwjgl:0"'
}

@test "writeControlifyConfig writes lwjgl:3 for slot 4" {
    writeControlifyConfig 4 3

    local cfg="$INSTANCES_DIR/latestUpdate-4/.minecraft/config/controlify/controlify.json"
    assert_file_contains "$cfg" '"lwjgl:3"'
}

@test "writeControlifyConfig creates config directory if missing" {
    rm -rf "$INSTANCES_DIR/latestUpdate-2/.minecraft/config/controlify"

    writeControlifyConfig 2 1

    local cfg="$INSTANCES_DIR/latestUpdate-2/.minecraft/config/controlify/controlify.json"
    [[ -f "$cfg" ]]
    assert_file_contains "$cfg" '"lwjgl:1"'
}

# ---------------------------------------------------------------------------
# clearControlifyConfig
# ---------------------------------------------------------------------------

@test "clearControlifyConfig removes the config file" {
    writeControlifyConfig 1 0
    local cfg="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controlify/controlify.json"
    [[ -f "$cfg" ]]

    clearControlifyConfig 1

    [[ ! -f "$cfg" ]]
}

@test "clearControlifyConfig is a no-op when config missing" {
    rm -f "$INSTANCES_DIR/latestUpdate-3/.minecraft/config/controlify/controlify.json"
    # Should not error
    run clearControlifyConfig 3
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# assignControllerToSlot — sequential assignment
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

@test "assignControllerToSlot writes Controlify config with correct joystick index" {
    assignControllerToSlot 2

    local cfg="$INSTANCES_DIR/latestUpdate-2/.minecraft/config/controlify/controlify.json"
    assert_file_contains "$cfg" '"lwjgl:1"'
}

@test "assignControllerToSlot slot 1 gets joystick index 0" {
    assignControllerToSlot 1

    local cfg="$INSTANCES_DIR/latestUpdate-1/.minecraft/config/controlify/controlify.json"
    assert_file_contains "$cfg" '"lwjgl:0"'
}
