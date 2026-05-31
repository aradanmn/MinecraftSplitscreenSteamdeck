#!/usr/bin/env bash
# =============================================================================
# Test helpers — shared setup/teardown for all test suites
# =============================================================================

# Create the entire fake environment under a temp directory.
setup_test_env() {
    TEST_ROOT=$(mktemp -d)
    export TEST_ROOT

    # Fake /dev/input
    mkdir -p "$TEST_ROOT/dev/input"
    for i in 0 1 2 3; do
        touch "$TEST_ROOT/dev/input/js${i}"
        touch "$TEST_ROOT/dev/input/event${i}"
    done

    # Fake sysfs Bluetooth serials (unique MAC per controller)
    for i in 0 1 2 3; do
        local sysfs="$TEST_ROOT/sys/class/input/event${i}/device"
        mkdir -p "$sysfs"
        printf "aa:bb:cc:dd:ee:0%d\n" "$i" > "$sysfs/uniq"
    done

    # Fake PrismLauncher instance tree
    INSTANCES_DIR="$TEST_ROOT/instances"
    export INSTANCES_DIR
    for slot in 1 2 3 4; do
        local mc="$INSTANCES_DIR/latestUpdate-${slot}/.minecraft"
        mkdir -p "$mc/config/controllable"
        mkdir -p "$mc/config/controlify"
        mkdir -p "$mc/mods"
        printf '[controller]\n\tautoSelect = true\n' > "$mc/config/controllable-client.toml"
    done
}

teardown_test_env() {
    [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
}

# Source the generated launcher script functions by:
#   1. Generating the script (with stub paths) into a temp file
#   2. Sourcing it (BASH_SOURCE guard skips the entry logic)
# Overrides hardware-dependent functions with mocks pointing at TEST_ROOT.
source_launcher_functions() {
    local generator="$BATS_TEST_DIRNAME/../../modules/launcher_script_generator.sh"
    local generated="$TEST_ROOT/minecraftSplitscreen.sh"

    # Stub print_* so generator doesn't spew output
    print_info()     { :; }
    print_success()  { :; }
    print_warning()  { :; }
    print_error()    { :; }
    print_progress() { :; }
    log()            { :; }

    # Set variables generate_splitscreen_launcher needs
    export ACTIVE_LAUNCHER="prismlauncher"
    export ACTIVE_LAUNCHER_TYPE="appimage"
    export ACTIVE_EXECUTABLE="$TEST_ROOT/PrismLauncher.AppImage"
    export ACTIVE_DATA_DIR="$TEST_ROOT"
    export ACTIVE_INSTANCES_DIR="$INSTANCES_DIR"
    export ACTIVE_LAUNCHER_SCRIPT="$generated"
    export SCRIPT_VERSION="3.3.0"
    export REPO_URL="https://github.com/aradanmn/MinecraftSplitscreenSteamdeck"

    # Source the generator (defines generate_splitscreen_launcher)
    # shellcheck disable=SC1090
    source "$generator"

    # Generate the launcher script (positional args match the function signature)
    generate_splitscreen_launcher \
        "$generated" \
        "prismlauncher" \
        "appimage" \
        "$TEST_ROOT/PrismLauncher.AppImage" \
        "$TEST_ROOT" \
        "$INSTANCES_DIR"

    # Create a stub AppImage so validate_launcher() passes the -x check
    # (the generated script calls it at top level before the BASH_SOURCE guard).
    touch "$TEST_ROOT/PrismLauncher.AppImage"
    chmod +x "$TEST_ROOT/PrismLauncher.AppImage"

    # Source the generated script — BASH_SOURCE guard prevents main loop
    # shellcheck disable=SC1090
    source "$generated"

    # Override hardware paths to point at TEST_ROOT
    findRealControllerEventDevices() {
        for i in 0 1 2 3; do
            echo "$TEST_ROOT/dev/input/event${i}"
        done
    }
    findSteamVirtualEventDevices() { :; }
    hasSteamVirtualController()    { return 1; }   # Desktop Mode

    # Redirect sysfs reads to TEST_ROOT
    getControllerSerial() {
        local event_dev="$1"
        local event_name="${event_dev##*/}"
        cat "$TEST_ROOT/sys/class/input/$event_name/device/uniq" 2>/dev/null \
            | tr '[:upper:]' '[:lower:]'
    }

    # Stub functions needing real hardware or a display
    writeInstanceSdlEnv()  { :; }
    clearInstanceSdlEnv()  { :; }
    showNotification()     { :; }
    repositionAllWindows() { :; }
    isSteamDeckHardware()  { return 1; }
    isSteamDeckDocked()    { return 1; }

    # Reset runtime state
    INSTANCE_ACTIVE=(0 0 0 0)
    INSTANCE_CONTROLLER_DEVICE=("" "" "" "")
    INSTANCE_PID=(0 0 0 0)
    INSTANCE_KNOWN_CONTROLLER=("" "" "" "")
    PLACEHOLDER_PID=""
    CURRENT_PLAYER_COUNT=0
    _SCREEN_DIMS_CACHE=""
}

# Assert a file contains a string
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: '$file' does not contain '$pattern'"
        echo "--- contents ---"
        cat "$file" 2>/dev/null || echo "(file not found)"
        return 1
    fi
}

# Assert a file does NOT contain a string
assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "FAIL: '$file' should not contain '$pattern'"
        grep "$pattern" "$file"
        return 1
    fi
}
