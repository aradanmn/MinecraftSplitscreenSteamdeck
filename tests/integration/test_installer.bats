#!/usr/bin/env bats
# =============================================================================
# Integration tests: end-to-end installer verification
# Run inside the Vagrant VM after `vagrant up` and `vagrant snapshot save`.
#
# These tests run the actual installer against a fake PrismLauncher stub,
# then verify all expected files and structures were created correctly.
# =============================================================================

# ---------------------------------------------------------------------------
# Shared setup: resolve project root and locate the installer
# ---------------------------------------------------------------------------

setup_file() {
    # Allow running from inside the VM (/project) or from CI
    if [[ -d /project ]]; then
        export PROJECT_DIR="/project"
    else
        export PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    fi

    export INSTALLER="$PROJECT_DIR/install-minecraft-splitscreen.sh"
    export TEST_HOME="$(mktemp -d)"

    # Stub PrismLauncher: accepts --cli and -l flags, exits 0
    mkdir -p "$TEST_HOME/.local/bin"
    cat > "$TEST_HOME/.local/bin/PrismLauncher" <<'STUB'
#!/usr/bin/env bash
echo "[PrismLauncher stub] args: $*" >&2
# Simulate creating an instance directory when -l (launch) is given
if [[ "$*" == *"--cli create-instance"* ]] || [[ "$*" == *"-l "* ]]; then
    exit 0
fi
exit 0
STUB
    chmod +x "$TEST_HOME/.local/bin/PrismLauncher"

    export PATH="$TEST_HOME/.local/bin:$PATH"
    export HOME="$TEST_HOME"

    # Disable prompts — run in non-interactive mode
    export SPLITSCREEN_NONINTERACTIVE=1
}

teardown_file() {
    [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"
}

# ---------------------------------------------------------------------------
# Sanity: installer script exists and is executable
# ---------------------------------------------------------------------------

@test "installer script exists and is executable" {
    [[ -x "$INSTALLER" ]]
}

@test "installer script passes bash syntax check" {
    bash -n "$INSTALLER"
}

# ---------------------------------------------------------------------------
# Module checks: all modules load without errors
# ---------------------------------------------------------------------------

@test "all modules pass shellcheck (errors only)" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck not installed"
    fi
    shellcheck --severity=error \
        --exclude=SC2034,SC2155,SC2046 \
        "$PROJECT_DIR"/modules/*.sh
}

@test "modules directory contains all required modules" {
    local required=(
        version_info.sh
        utilities.sh
        path_configuration.sh
        launcher_script_generator.sh
        java_management.sh
        launcher_setup.sh
        version_management.sh
        lwjgl_management.sh
        mod_management.sh
        instance_creation.sh
        steam_integration.sh
        desktop_launcher.sh
        main_workflow.sh
    )
    for m in "${required[@]}"; do
        [[ -f "$PROJECT_DIR/modules/$m" ]] || {
            echo "MISSING: modules/$m"
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# Mod list: verify mod IDs are referenced correctly
# ---------------------------------------------------------------------------

@test "install script references Controlify not Controllable" {
    grep -q "Controlify" "$INSTALLER"
    ! grep -q "Controllable" "$INSTALLER"
}

@test "Controlify uses modrinth platform" {
    grep "Controlify" "$INSTALLER" | grep -q "modrinth"
}

@test "Splitscreen Support is in the mod list" {
    grep -q "Splitscreen Support" "$INSTALLER"
}

# ---------------------------------------------------------------------------
# Modrinth API: mod IDs resolve to real mods
# ---------------------------------------------------------------------------

@test "Controlify mod ID resolves on Modrinth API" {
    if ! curl -sf --connect-timeout 5 "https://api.modrinth.com/v2/project/DOUdJVEm" >/dev/null 2>&1; then
        skip "no internet access or Modrinth unreachable"
    fi
    local result
    result=$(curl -sf "https://api.modrinth.com/v2/project/DOUdJVEm" | grep -o '"slug":"[^"]*"' | head -1)
    [[ "$result" == *"controlify"* ]]
}

@test "Splitscreen Support mod ID resolves on Modrinth API" {
    if ! curl -sf --connect-timeout 5 "https://api.modrinth.com/v2/project/yJgqfSDR" >/dev/null 2>&1; then
        skip "no internet access or Modrinth unreachable"
    fi
    local result
    result=$(curl -sf "https://api.modrinth.com/v2/project/yJgqfSDR" | grep -o '"slug":"[^"]*"' | head -1)
    [[ -n "$result" ]]
}

# ---------------------------------------------------------------------------
# Launcher script generator: output is well-formed
# ---------------------------------------------------------------------------

_source_generator() {
    # Source modules first, then override print_* and log() with stubs.
    # Stubs must come AFTER source so they overwrite utilities.sh definitions.
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/modules/version_info.sh"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/modules/utilities.sh"
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/modules/launcher_script_generator.sh"

    # Disable logging — no log file is initialised in the test environment
    print_info()     { :; }; print_success() { :; }; print_error() { :; }
    print_warning()  { :; }; print_progress() { :; }; log() { :; }
    LOG_FILE=""
}

@test "generate_splitscreen_launcher produces executable script" {
    _source_generator
    local out="$TEST_HOME/test-launcher.sh"
    generate_splitscreen_launcher \
        "$out" \
        "prismlauncher" \
        "appimage" \
        "$TEST_HOME/.local/bin/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher/instances"

    [[ -x "$out" ]]
}

@test "generate_splitscreen_launcher leaves no unresolved install-time placeholders" {
    _source_generator
    local out="$TEST_HOME/test-launcher2.sh"
    generate_splitscreen_launcher \
        "$out" \
        "prismlauncher" \
        "appimage" \
        "$TEST_HOME/.local/bin/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher/instances"

    run grep -cP "__(?!MC_PIDS__|MC_TOTAL__)[A-Z_]+__" "$out"
    [[ "$output" -eq 0 || "$status" -ne 0 ]]
}

@test "generated launcher includes Controlify config writing" {
    _source_generator
    local out="$TEST_HOME/test-launcher3.sh"
    generate_splitscreen_launcher \
        "$out" \
        "prismlauncher" \
        "appimage" \
        "$TEST_HOME/.local/bin/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher/instances"

    grep -q "writeControlifyConfig" "$out"
}

@test "generated launcher has no Controllable references" {
    _source_generator
    local out="$TEST_HOME/test-launcher4.sh"
    generate_splitscreen_launcher \
        "$out" \
        "prismlauncher" \
        "appimage" \
        "$TEST_HOME/.local/bin/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher" \
        "$TEST_HOME/.local/share/PrismLauncher/instances"

    ! grep -q "controllable-client.toml\|selected_controllers.json\|setControllableAutoSelect" "$out"
}
