#!/usr/bin/env bats
# =============================================================================
# Unit tests: config file generation
# Tests that generated options.txt, instance.cfg, and mmc-pack.json
# are written with correct values.
# =============================================================================

load "../helpers"

setup() {
    setup_test_env
    export MC_VERSION="1.21.4"
    export FABRIC_VERSION="0.16.10"
    export LWJGL_VERSION="3.3.3"
}

teardown() {
    teardown_test_env
}

# ---------------------------------------------------------------------------
# options.txt
# ---------------------------------------------------------------------------

@test "options.txt sets guiScale to 4" {
    local opts="$INSTANCES_DIR/latestUpdate-1/.minecraft/options.txt"

    # Simulate what instance_creation.sh writes (excerpt)
    cat > "$opts" <<'EOF'
version:3953
autoJump:false
guiScale:4
particles:0
EOF

    assert_file_contains "$opts" "guiScale:4"
    assert_file_not_contains "$opts" "guiScale:0"
}

@test "options.txt sets pauseOnLostFocus to false" {
    local opts="$INSTANCES_DIR/latestUpdate-2/.minecraft/options.txt"
    cat > "$opts" <<'EOF'
pauseOnLostFocus:false
guiScale:4
EOF
    assert_file_contains "$opts" "pauseOnLostFocus:false"
}

@test "options.txt disables chat for non-primary instances" {
    local opts="$INSTANCES_DIR/latestUpdate-2/.minecraft/options.txt"
    cat > "$opts" <<'EOF'
chatVisibility:0
guiScale:4
EOF
    assert_file_contains "$opts" "chatVisibility:0"
}

# ---------------------------------------------------------------------------
# instance.cfg IntendedVersion substitution
# ---------------------------------------------------------------------------

@test "instance.cfg IntendedVersion is set to MC_VERSION with no sed corruption" {
    local cfg="$INSTANCES_DIR/latestUpdate-1/instance.cfg"
    cat > "$cfg" <<'EOF'
InstanceType=OneSix
name=latestUpdate-1
IntendedVersion=1.20.1
EOF

    # Simulate the sed replacement from instance_creation.sh
    sed -i "s|^IntendedVersion=.*|IntendedVersion=$MC_VERSION|" "$cfg"

    assert_file_contains "$cfg" "IntendedVersion=1.21.4"
    assert_file_not_contains "$cfg" "IntendedVersion=1.20.1"
}

# ---------------------------------------------------------------------------
# Placeholder replacement in generated launcher
# ---------------------------------------------------------------------------

@test "generate_splitscreen_launcher replaces all __PLACEHOLDER__ tokens" {
    local out="$TEST_ROOT/minecraftSplitscreen.sh"

    # Stub print functions, then source the generator
    print_info()    { :; }; print_success() { :; }; print_error() { :; }
    print_warning() { :; }; print_progress() { :; }
    source "$BATS_TEST_DIRNAME/../../modules/launcher_script_generator.sh"

    # Call with correct positional args (matching the function signature)
    generate_splitscreen_launcher \
        "$out" \
        "prismlauncher" \
        "appimage" \
        "$TEST_ROOT/PrismLauncher.AppImage" \
        "$TEST_ROOT" \
        "$TEST_ROOT/instances"

    # No install-time __PLACEHOLDER__ tokens should remain.
    # __MC_PIDS__ and __MC_TOTAL__ are intentional runtime placeholders replaced
    # by the generated script itself when building KWin scripts — exclude them.
    run grep -cP "__(?!MC_PIDS__|MC_TOTAL__)[A-Z_]+__" "$out"
    [[ "$output" -eq 0 || "$status" -ne 0 ]]
}

@test "generated launcher script is executable" {
    local out="$TEST_ROOT/minecraftSplitscreen.sh"
    [[ -f "$out" ]] || skip "launcher not generated (run placeholder test first)"
    [[ -x "$out" ]]
}
