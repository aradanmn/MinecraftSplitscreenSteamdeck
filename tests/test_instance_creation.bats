#!/usr/bin/env bats
# =============================================================================
# @file test_instance_creation.bats
# @description BATS tests for modules/instance_creation.sh.
#
# Focuses on the two testable units that don't require PrismLauncher or
# network access:
#
#   handle_instance_update — preserves options.txt, clears mods dir,
#                            updates instance.cfg and mmc-pack.json
#
#   create_instances (manual path) — when get_prism_executable() fails,
#                            creates the 4-instance directory structure
#                            and writes valid config files
#
# Mocking approach:
#   - HOME redirected to mktemp so path constants stay in throwaway dirs
#   - get_prism_executable() → returns 1 (forces manual creation path)
#   - install_fabric_and_mods() → no-op (avoids Fabric download)
#   - CREATION_INSTANCES_DIR set directly to a temp dir
#
# Usage:
#   bats tests/test_instance_creation.bats
# =============================================================================

setup() {
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"

    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"

    PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MODULES_DIR="$PROJECT_DIR/modules"

    # Pre-source stubs.
    print_header()    { :; }
    is_immutable_os() { return 1; }

    source "$MODULES_DIR/version_info.sh"
    source "$MODULES_DIR/utilities.sh"
    source "$MODULES_DIR/path_configuration.sh"
    source "$MODULES_DIR/launcher_setup.sh"
    source "$MODULES_DIR/instance_creation.sh"

    # Re-apply after sourcing.
    LOG_FILE=/dev/null
    print_header()    { :; }
    print_success()   { :; }
    print_warning()   { :; }
    print_error()     { :; }
    print_info()      { :; }
    print_progress()  { :; }

    # Force manual creation path — no PrismLauncher CLI available.
    get_prism_executable() { return 1; }

    # Avoid network calls — mod/Fabric installation is out of scope here.
    install_fabric_and_mods() { :; }

    # Standard version globals used by all instance tests.
    MC_VERSION="1.21.4"
    FABRIC_VERSION="0.16.10"
    LWJGL_VERSION="3.3.3"

    # Redirect instance storage to a temp dir.
    INSTANCES_DIR="$TEST_HOME/instances"
    mkdir -p "$INSTANCES_DIR"
    CREATION_INSTANCES_DIR="$INSTANCES_DIR"

    FINAL_MOD_INDEXES=()
    MISSING_MODS=()
}

teardown() {
    rm -rf "$TEST_HOME"
}

# =============================================================================
# handle_instance_update
# =============================================================================

@test "handle_instance_update: clears mods directory" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft/mods"
    touch "$inst/.minecraft/mods/old-mod.jar"

    handle_instance_update "$inst" "latestUpdate-1" > /dev/null

    [ ! -d "$inst/.minecraft/mods" ]
}

@test "handle_instance_update: preserves options.txt and returns 'true'" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft"
    echo "key=value" > "$inst/.minecraft/options.txt"
    touch "$inst/instance.cfg"

    local result
    result=$(handle_instance_update "$inst" "latestUpdate-1" 2>/dev/null)

    [ "$result" = "true" ]
    [ -f "$inst/.minecraft/options.txt" ]
    [ "$(cat "$inst/.minecraft/options.txt")" = "key=value" ]
}

@test "handle_instance_update: returns 'false' when no options.txt exists" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft"
    touch "$inst/instance.cfg"

    local result
    result=$(handle_instance_update "$inst" "latestUpdate-1" 2>/dev/null)

    [ "$result" = "false" ]
}

@test "handle_instance_update: updates IntendedVersion in instance.cfg" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft"
    printf 'InstanceType=OneSix\nIntendedVersion=1.20.4\n' > "$inst/instance.cfg"

    handle_instance_update "$inst" "latestUpdate-1" > /dev/null

    grep -q "^IntendedVersion=1.21.4$" "$inst/instance.cfg"
}

@test "handle_instance_update: writes mmc-pack.json with correct MC and Fabric versions" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft"
    touch "$inst/instance.cfg"

    handle_instance_update "$inst" "latestUpdate-1" > /dev/null

    [ -f "$inst/mmc-pack.json" ]
    grep -q '"version": "1.21.4"' "$inst/mmc-pack.json"
    grep -q '"version": "0.16.10"' "$inst/mmc-pack.json"
    grep -q '"version": "3.3.3"' "$inst/mmc-pack.json"
    grep -q '"uid": "net.fabricmc.fabric-loader"' "$inst/mmc-pack.json"
    grep -q '"uid": "net.minecraft"' "$inst/mmc-pack.json"
}

@test "handle_instance_update: mmc-pack.json is valid JSON" {
    local inst="$INSTANCES_DIR/latestUpdate-1"
    mkdir -p "$inst/.minecraft"
    touch "$inst/instance.cfg"

    handle_instance_update "$inst" "latestUpdate-1" > /dev/null

    jq -e . "$inst/mmc-pack.json" > /dev/null
}

# =============================================================================
# create_instances (manual creation path)
# =============================================================================

@test "create_instances: creates all 4 instance directories" {
    create_instances

    for i in 1 2 3 4; do
        [ -d "$INSTANCES_DIR/latestUpdate-$i" ]
    done
}

@test "create_instances: each instance has a .minecraft subdirectory" {
    create_instances

    for i in 1 2 3 4; do
        [ -d "$INSTANCES_DIR/latestUpdate-$i/.minecraft" ]
    done
}

@test "create_instances: each instance.cfg has correct IntendedVersion" {
    create_instances

    for i in 1 2 3 4; do
        grep -q "^IntendedVersion=1.21.4$" "$INSTANCES_DIR/latestUpdate-$i/instance.cfg"
    done
}

@test "create_instances: each instance.cfg has InstanceType=OneSix" {
    create_instances

    for i in 1 2 3 4; do
        grep -q "^InstanceType=OneSix$" "$INSTANCES_DIR/latestUpdate-$i/instance.cfg"
    done
}

@test "create_instances: each mmc-pack.json contains correct version UIDs" {
    create_instances

    for i in 1 2 3 4; do
        local f="$INSTANCES_DIR/latestUpdate-$i/mmc-pack.json"
        [ -f "$f" ]
        grep -q '"uid": "net.minecraft"' "$f"
        grep -q '"uid": "net.fabricmc.fabric-loader"' "$f"
        grep -q '"uid": "org.lwjgl3"' "$f"
    done
}

@test "create_instances: each mmc-pack.json is valid JSON" {
    create_instances

    for i in 1 2 3 4; do
        jq -e . "$INSTANCES_DIR/latestUpdate-$i/mmc-pack.json" > /dev/null
    done
}

@test "create_instances: MC_VERSION missing → exits non-zero" {
    unset MC_VERSION
    run create_instances
    [ "$status" -ne 0 ]
}

@test "create_instances: FABRIC_VERSION missing → exits non-zero" {
    unset FABRIC_VERSION
    run create_instances
    [ "$status" -ne 0 ]
}
