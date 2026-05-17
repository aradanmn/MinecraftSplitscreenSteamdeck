#!/usr/bin/env bash
# =============================================================================
# @file test_integration.sh
# @description End-to-end integration test for the full installation workflow.
#
# Runs main() with all network and interactive calls mocked, then asserts on
# the final on-disk state: instance directories, config file contents, and
# the generated minecraftSplitscreen.sh launcher script.
#
# What is tested here (vs unit tests):
#   - Phase ordering: configure_launcher_paths → create_instances →
#     generate_launcher_script fires in the right sequence
#   - Path wiring: CREATION_INSTANCES_DIR is correctly used for instance
#     creation, ACTIVE_LAUNCHER_SCRIPT for the launcher
#   - Config file correctness: instance.cfg IntendedVersion and
#     mmc-pack.json component UIDs reflect the globals set by the
#     version-detection mocks
#   - Script generation end-to-end: generate_splitscreen_launcher writes a
#     syntactically valid script with no unreplaced placeholders
#
# What is NOT tested:
#   - Network calls (all mocked via tests/bin/curl and tests/bin/wget stubs)
#   - Interactive user prompts (mocked at function level)
#   - Fabric/mod download (install_fabric_and_mods is a no-op)
#   - Steam/desktop integration (mocked)
#   - Actual Minecraft launching (requires GPU/display/hardware)
#
# Usage:
#   bash tests/test_integration.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULES_DIR="$PROJECT_DIR/modules"

# Redirect HOME before any sourcing so the readonly path constants
# (PRISM_APPIMAGE_DATA_DIR, PRISM_FLATPAK_DATA_DIR, PRISM_APPIMAGE_PATH)
# resolve into a throwaway temp directory.
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"

# Prepend stubs: curl (API fixture router), wget (fails gracefully), flatpak
export PATH="$SCRIPT_DIR/bin:$PATH"

# =============================================================================
# Assertion framework
# =============================================================================

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected: %s\n        actual:   %s\n" \
            "$desc" "$expected" "$actual"
        (( FAIL++ )) || true
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        looking for: %s\n" "$desc" "$needle"
        (( FAIL++ )) || true
    fi
}

assert_return() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [[ "$expected_rc" == "$actual_rc" ]]; then
        (( PASS++ )) || true
    else
        printf "  FAIL  %s\n        expected rc: %s  actual rc: %s\n" \
            "$desc" "$expected_rc" "$actual_rc"
        (( FAIL++ )) || true
    fi
}

run_test() { echo "--- $1"; }

# =============================================================================
# Pre-source stubs (some overwritten by modules; re-applied after sourcing)
# =============================================================================

print_header()    { :; }
is_immutable_os() { return 1; }  # traditional OS → AppImage preferred

# =============================================================================
# Source all modules in dependency order
# =============================================================================

source "$MODULES_DIR/version_info.sh"
source "$MODULES_DIR/utilities.sh"
source "$MODULES_DIR/path_configuration.sh"
source "$MODULES_DIR/launcher_setup.sh"
source "$MODULES_DIR/version_management.sh"
source "$MODULES_DIR/java_management.sh"
source "$MODULES_DIR/lwjgl_management.sh"
source "$MODULES_DIR/mod_management.sh"
source "$MODULES_DIR/instance_creation.sh"
source "$MODULES_DIR/launcher_script_generator.sh"
source "$MODULES_DIR/steam_integration.sh"
source "$MODULES_DIR/desktop_launcher.sh"
source "$MODULES_DIR/main_workflow.sh"

# =============================================================================
# Post-source: silence output and override network/interactive functions
# =============================================================================

# LOG_FILE=/dev/null keeps log() from returning 1 when LOG_FILE is unset.
LOG_FILE=/dev/null
print_header()    { :; }
print_success()   { :; }
print_warning()   { :; }
print_error()     { :; }
print_info()      { :; }
print_progress()  { :; }
is_immutable_os() { return 1; }

# -- Logging --
init_logging() { :; }
get_log_file()  { echo "/dev/null"; }

# -- Version detection: bypass Mojang/Fabric APIs and interactive prompts --
get_minecraft_version() { MC_VERSION="1.21.4"; }
get_fabric_version()    { FABRIC_VERSION="0.16.10"; }
get_lwjgl_version()     { LWJGL_VERSION="3.3.3"; }

# -- Java: skip detection and optional download --
detect_and_install_java() { JAVA_PATH="/usr/bin/java"; JAVA_VERSION="21"; }

# -- PrismLauncher: AppImage "present" via fake file; CLI unavailable so
#    create_instances falls through to the manual directory-creation path --
download_prism_launcher() { :; }
verify_prism_cli()        { return 0; }
get_prism_executable()    { return 1; }

# -- Mod/Fabric download: out of scope for this test --
install_fabric_and_mods() { :; }

# -- Mod selection: populate globals with known-good mods, select all --
check_mod_compatibility() {
    SUPPORTED_MODS=("Fabric API" "Controllable (Fabric)" "Splitscreen Support")
    MOD_DESCRIPTIONS=("" "" "")
    MOD_URLS=(
        "https://cdn.modrinth.com/data/P7dR8mSH/versions/AABBCCDD/fabric-api-0.110.0+1.21.4.jar"
        "https://edge.forgecdn.net/files/4567/890/controllable-0.21.0+1.21.4-fabric.jar"
        "https://cdn.modrinth.com/data/yJgqfSDR/versions/SSVV0001/splitscreen-1.0.0+1.21.4.jar"
    )
    MOD_IDS=("P7dR8mSH" "317269" "yJgqfSDR")
    MOD_TYPES=("modrinth" "curseforge" "modrinth")
    MOD_DEPENDENCIES=("" "" "P7dR8mSH")
}
select_user_mods()          { FINAL_MOD_INDEXES=(0 1 2); }
resolve_all_dependencies()  { :; }

# -- System integration: optional, out of scope --
merge_accounts_json()             { return 0; }
setup_steam_integration()         { :; }
create_desktop_launcher()         { :; }
check_dynamic_mode_dependencies() { :; }

# =============================================================================
# Global arrays declared in install-minecraft-splitscreen.sh (not in modules)
# =============================================================================

declare -a REQUIRED_SPLITSCREEN_MODS=("Controllable (Fabric)" "Splitscreen Support")
declare -a REQUIRED_SPLITSCREEN_IDS=("317269" "yJgqfSDR")
declare -a MODS=(
    "Fabric API|modrinth|P7dR8mSH"
    "Controllable (Fabric)|curseforge|317269"
    "Splitscreen Support|modrinth|yJgqfSDR"
)
declare -a SUPPORTED_MODS=()
declare -a MOD_DESCRIPTIONS=()
declare -a MOD_URLS=()
declare -a MOD_IDS=()
declare -a MOD_TYPES=()
declare -a MOD_DEPENDENCIES=()
declare -a FINAL_MOD_INDEXES=()
declare -a MISSING_MODS=()

JAVA_PATH=""
MC_VERSION=""
FABRIC_VERSION=""
LWJGL_VERSION=""

# =============================================================================
# Place the fake AppImage so configure_launcher_paths() detects PrismLauncher
# =============================================================================

mkdir -p "$(dirname "$PRISM_APPIMAGE_PATH")"
touch "$PRISM_APPIMAGE_PATH" && chmod +x "$PRISM_APPIMAGE_PATH"

# =============================================================================
# Run the full installation workflow
# =============================================================================

run_test "Integration: main() completes without error"
install_rc=0
main > /dev/null 2>&1 || install_rc=$?
assert_return "main() exits 0" "0" "$install_rc"

# Capture instance dir for subsequent assertions.
INSTANCES_DIR="${ACTIVE_INSTANCES_DIR:-}"

# =============================================================================
# Phase 1: Launcher path configuration
# =============================================================================

run_test "Integration: path configuration wired correctly"
assert_eq "ACTIVE_LAUNCHER is prismlauncher"   "prismlauncher" "${ACTIVE_LAUNCHER:-}"
assert_eq "ACTIVE_LAUNCHER_TYPE is appimage"   "appimage"      "${ACTIVE_LAUNCHER_TYPE:-}"
assert_eq "MC_VERSION set to 1.21.4"           "1.21.4"        "${MC_VERSION:-}"
assert_eq "FABRIC_VERSION set to 0.16.10"      "0.16.10"       "${FABRIC_VERSION:-}"
assert_eq "LWJGL_VERSION set to 3.3.3"         "3.3.3"         "${LWJGL_VERSION:-}"

# =============================================================================
# Phase 2: Instance creation
# =============================================================================

run_test "Integration: all 4 instance directories created"
for i in 1 2 3 4; do
    assert_eq "latestUpdate-$i directory exists" \
        "true" "$( [[ -d "$INSTANCES_DIR/latestUpdate-$i" ]] && echo true || echo false )"
done

run_test "Integration: instance.cfg has correct fields"
for i in 1 2 3 4; do
    cfg="$INSTANCES_DIR/latestUpdate-$i/instance.cfg"
    assert_eq "latestUpdate-$i instance.cfg exists" \
        "true" "$( [[ -f "$cfg" ]] && echo true || echo false )"
    if [[ -f "$cfg" ]]; then
        assert_eq "latestUpdate-$i InstanceType=OneSix" \
            "OneSix" "$(grep -m1 '^InstanceType=' "$cfg" | cut -d= -f2)"
        assert_eq "latestUpdate-$i IntendedVersion=1.21.4" \
            "1.21.4" "$(grep -m1 '^IntendedVersion=' "$cfg" | cut -d= -f2)"
    fi
done

run_test "Integration: mmc-pack.json is valid JSON with correct component UIDs"
for i in 1 2 3 4; do
    pack="$INSTANCES_DIR/latestUpdate-$i/mmc-pack.json"
    assert_eq "latestUpdate-$i mmc-pack.json exists" \
        "true" "$( [[ -f "$pack" ]] && echo true || echo false )"
    if [[ -f "$pack" ]]; then
        assert_eq "latestUpdate-$i mmc-pack.json is valid JSON" \
            "true" "$(jq -e . "$pack" >/dev/null 2>&1 && echo true || echo false)"
        assert_contains "latestUpdate-$i has net.minecraft UID" \
            "net.minecraft" "$(<"$pack")"
        assert_contains "latestUpdate-$i has fabric-loader UID" \
            "net.fabricmc.fabric-loader" "$(<"$pack")"
        assert_contains "latestUpdate-$i has lwjgl3 UID" \
            "org.lwjgl3" "$(<"$pack")"
        assert_contains "latestUpdate-$i has MC version 1.21.4" \
            '"version": "1.21.4"' "$(<"$pack")"
    fi
done

# =============================================================================
# Phase 3: Launcher script generation
# =============================================================================

run_test "Integration: minecraftSplitscreen.sh generated and executable"
assert_eq "launcher script exists" \
    "true" "$( [[ -f "${ACTIVE_LAUNCHER_SCRIPT:-}" ]] && echo true || echo false )"
assert_eq "launcher script is executable" \
    "true" "$( [[ -x "${ACTIVE_LAUNCHER_SCRIPT:-}" ]] && echo true || echo false )"

run_test "Integration: generated script passes bash -n syntax check"
if [[ -f "${ACTIVE_LAUNCHER_SCRIPT:-}" ]]; then
    assert_return "bash -n exits 0" \
        "0" "$(bash -n "$ACTIVE_LAUNCHER_SCRIPT" 2>/dev/null; echo $?)"
fi

run_test "Integration: generated script has no unreplaced __LAUNCHER_ placeholders"
if [[ -f "${ACTIVE_LAUNCHER_SCRIPT:-}" ]]; then
    placeholder_count=$(grep -c '__LAUNCHER_' "$ACTIVE_LAUNCHER_SCRIPT" 2>/dev/null || true)
    assert_eq "0 unreplaced placeholders" "0" "$placeholder_count"
fi

run_test "Integration: generated script embeds correct launcher configuration"
if [[ -f "${ACTIVE_LAUNCHER_SCRIPT:-}" ]]; then
    assert_contains "script references prismlauncher" \
        "prismlauncher" "$(<"$ACTIVE_LAUNCHER_SCRIPT")"
    assert_contains "script references appimage type" \
        "appimage" "$(<"$ACTIVE_LAUNCHER_SCRIPT")"
    assert_contains "script references instances dir" \
        "latestUpdate" "$(<"$ACTIVE_LAUNCHER_SCRIPT")"
fi

# =============================================================================
# Cleanup
# =============================================================================

rm -rf "$TEST_HOME"

# =============================================================================
# Summary
# =============================================================================

echo ""
printf "Results: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
