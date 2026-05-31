#!/usr/bin/env bats
# =============================================================================
# @file test_path_configuration.bats
# @description BATS tests for modules/path_configuration.sh
#
# Covers is_flatpak_installed, is_appimage_available, detect_prismlauncher,
# set_creation_launcher_prismlauncher, and configure_launcher_paths.
#
# Key setup choices:
#   - HOME is redirected to a temp dir before sourcing so the readonly path
#     constants (PRISM_APPIMAGE_DATA_DIR, PRISM_FLATPAK_DATA_DIR,
#     PRISM_APPIMAGE_PATH) resolve into the temp dir and never touch the
#     real system.
#   - _FLATPAK_LIST_CACHE is injected directly to control is_flatpak_installed
#     without needing a real flatpak installation.
#   - tests/bin/flatpak stub is prepended to PATH so `command -v flatpak`
#     succeeds. The stub is bypassed whenever _FLATPAK_LIST_CACHE is set.
#   - Print mocks are applied AFTER sourcing because utilities.sh overwrites
#     any pre-source definitions.
#
# Usage:
#   bats tests/test_path_configuration.bats
# =============================================================================

setup() {
    # Redirect HOME so readonly path constants (set at source time) resolve
    # into a throwaway temp directory instead of the real system.
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"

    # Prepend stub directory: provides a fake `flatpak` binary so that
    # `command -v flatpak` succeeds inside is_flatpak_installed.
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"

    PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MODULES_DIR="$PROJECT_DIR/modules"

    # Pre-source stubs (some are overwritten by utilities.sh below).
    print_header()    { :; }
    is_immutable_os() { return 1; }  # default: traditional OS

    source "$MODULES_DIR/version_info.sh"
    source "$MODULES_DIR/utilities.sh"
    source "$MODULES_DIR/path_configuration.sh"

    # Re-apply after sourcing so utilities.sh definitions don't win.
    # LOG_FILE=/dev/null prevents log() returning 1 when LOG_FILE is unset.
    LOG_FILE=/dev/null
    print_header()    { :; }
    print_success()   { :; }
    print_warning()   { :; }
    print_error()     { :; }
    print_info()      { :; }
    print_progress()  { :; }
    is_immutable_os() { return 1; }
}

teardown() {
    rm -rf "$TEST_HOME"
}

# =============================================================================
# is_appimage_available
# =============================================================================

@test "is_appimage_available: missing file returns 1" {
    run is_appimage_available "$TEST_HOME/nonexistent.AppImage"
    [ "$status" -eq 1 ]
}

@test "is_appimage_available: existing non-executable file returns 1" {
    local f="$TEST_HOME/PrismLauncher.AppImage"
    touch "$f"
    run is_appimage_available "$f"
    [ "$status" -eq 1 ]
}

@test "is_appimage_available: existing executable file returns 0" {
    local f="$TEST_HOME/PrismLauncher.AppImage"
    touch "$f" && chmod +x "$f"
    run is_appimage_available "$f"
    [ "$status" -eq 0 ]
}

# =============================================================================
# is_flatpak_installed
# =============================================================================

@test "is_flatpak_installed: ID present in cache returns 0" {
    _FLATPAK_LIST_CACHE="org.prismlauncher.PrismLauncher"
    run is_flatpak_installed "org.prismlauncher.PrismLauncher"
    [ "$status" -eq 0 ]
}

@test "is_flatpak_installed: ID absent from cache returns 1" {
    _FLATPAK_LIST_CACHE="org.someother.App"
    run is_flatpak_installed "org.prismlauncher.PrismLauncher"
    [ "$status" -eq 1 ]
}

@test "is_flatpak_installed: flatpak not in PATH returns 1" {
    _FLATPAK_LIST_CACHE=""
    # Run in a subshell with a minimal PATH that excludes tests/bin,
    # so `command -v flatpak` fails and the function short-circuits to return 1.
    local rc=0
    ( PATH="/usr/bin:/bin" is_flatpak_installed "org.prismlauncher.PrismLauncher" ) || rc=$?
    [ "$rc" -eq 1 ]
}

# =============================================================================
# detect_prismlauncher
# =============================================================================

@test "detect_prismlauncher: PREFER_FLATPAK=false, AppImage present → type=appimage" {
    PREFER_FLATPAK=false
    _FLATPAK_LIST_CACHE=""
    mkdir -p "$(dirname "$PRISM_APPIMAGE_PATH")"
    touch "$PRISM_APPIMAGE_PATH" && chmod +x "$PRISM_APPIMAGE_PATH"

    detect_prismlauncher
    [ "$PRISM_TYPE"       = "appimage" ]
    [ "$PRISM_DATA_DIR"   = "$PRISM_APPIMAGE_DATA_DIR" ]
    [ "$PRISM_EXECUTABLE" = "$PRISM_APPIMAGE_PATH" ]
}

@test "detect_prismlauncher: PREFER_FLATPAK=false, no AppImage, flatpak in cache → type=flatpak" {
    PREFER_FLATPAK=false
    _FLATPAK_LIST_CACHE="org.prismlauncher.PrismLauncher"
    # No AppImage file exists under TEST_HOME.

    detect_prismlauncher
    [ "$PRISM_TYPE"       = "flatpak" ]
    [ "$PRISM_DATA_DIR"   = "$PRISM_FLATPAK_DATA_DIR" ]
    [ "$PRISM_EXECUTABLE" = "flatpak run $PRISM_FLATPAK_ID" ]
}

@test "detect_prismlauncher: PREFER_FLATPAK=false, neither available → returns 1" {
    PREFER_FLATPAK=false
    _FLATPAK_LIST_CACHE="org.someother.App"
    # No AppImage file.

    run detect_prismlauncher
    [ "$status" -eq 1 ]
}

@test "detect_prismlauncher: PREFER_FLATPAK=true, flatpak in cache → flatpak preferred over AppImage" {
    PREFER_FLATPAK=true
    _FLATPAK_LIST_CACHE="org.prismlauncher.PrismLauncher"
    # Also create AppImage — flatpak should still win.
    mkdir -p "$(dirname "$PRISM_APPIMAGE_PATH")"
    touch "$PRISM_APPIMAGE_PATH" && chmod +x "$PRISM_APPIMAGE_PATH"

    detect_prismlauncher
    [ "$PRISM_TYPE" = "flatpak" ]
}

@test "detect_prismlauncher: PREFER_FLATPAK=true, no flatpak, AppImage present → appimage fallback" {
    PREFER_FLATPAK=true
    _FLATPAK_LIST_CACHE="org.someother.App"
    mkdir -p "$(dirname "$PRISM_APPIMAGE_PATH")"
    touch "$PRISM_APPIMAGE_PATH" && chmod +x "$PRISM_APPIMAGE_PATH"

    detect_prismlauncher
    [ "$PRISM_TYPE" = "appimage" ]
}

# =============================================================================
# set_creation_launcher_prismlauncher
# =============================================================================

@test "set_creation_launcher_prismlauncher: appimage type sets CREATION vars and creates instances dir" {
    ACTIVE_LAUNCHER=""
    set_creation_launcher_prismlauncher "appimage" "/path/to/PrismLauncher.AppImage"

    [ "$CREATION_LAUNCHER"       = "prismlauncher" ]
    [ "$CREATION_LAUNCHER_TYPE"  = "appimage" ]
    [ "$CREATION_DATA_DIR"       = "$PRISM_APPIMAGE_DATA_DIR" ]
    [ "$CREATION_INSTANCES_DIR"  = "$PRISM_APPIMAGE_DATA_DIR/instances" ]
    [ "$CREATION_EXECUTABLE"     = "/path/to/PrismLauncher.AppImage" ]
    [ -d "$CREATION_INSTANCES_DIR" ]
}

@test "set_creation_launcher_prismlauncher: flatpak type sets CREATION_DATA_DIR to flatpak path" {
    ACTIVE_LAUNCHER=""
    set_creation_launcher_prismlauncher "flatpak" "flatpak run org.prismlauncher.PrismLauncher"

    [ "$CREATION_LAUNCHER_TYPE" = "flatpak" ]
    [ "$CREATION_DATA_DIR"      = "$PRISM_FLATPAK_DATA_DIR" ]
    [ "$CREATION_INSTANCES_DIR" = "$PRISM_FLATPAK_DATA_DIR/instances" ]
    [ -d "$CREATION_INSTANCES_DIR" ]
}

@test "set_creation_launcher_prismlauncher: ACTIVE_LAUNCHER empty → also populates ACTIVE vars" {
    ACTIVE_LAUNCHER=""
    set_creation_launcher_prismlauncher "appimage" "/path/to/PrismLauncher.AppImage"

    [ "$ACTIVE_LAUNCHER"        = "prismlauncher" ]
    [ "$ACTIVE_LAUNCHER_TYPE"   = "appimage" ]
    [ "$ACTIVE_DATA_DIR"        = "$PRISM_APPIMAGE_DATA_DIR" ]
    [ "$ACTIVE_LAUNCHER_SCRIPT" = "$PRISM_APPIMAGE_DATA_DIR/minecraftSplitscreen.sh" ]
}

@test "set_creation_launcher_prismlauncher: ACTIVE_LAUNCHER already set → ACTIVE vars unchanged" {
    ACTIVE_LAUNCHER="already-set"
    ACTIVE_LAUNCHER_TYPE="existing-type"
    set_creation_launcher_prismlauncher "appimage" "/path/to/PrismLauncher.AppImage"

    [ "$ACTIVE_LAUNCHER"      = "already-set" ]
    [ "$ACTIVE_LAUNCHER_TYPE" = "existing-type" ]
}

# =============================================================================
# configure_launcher_paths (integration)
# =============================================================================

@test "configure_launcher_paths: immutable OS detection sets PREFER_FLATPAK=true" {
    is_immutable_os() { IMMUTABLE_OS_NAME="TestOS"; return 0; }
    PREFER_FLATPAK=false
    IMMUTABLE_OS_DETECTED=false

    configure_launcher_paths

    [ "$PREFER_FLATPAK"        = "true" ]
    [ "$IMMUTABLE_OS_DETECTED" = "true" ]
}

@test "configure_launcher_paths: traditional OS with AppImage → CREATION and ACTIVE set to appimage" {
    is_immutable_os() { return 1; }
    _FLATPAK_LIST_CACHE=""
    mkdir -p "$(dirname "$PRISM_APPIMAGE_PATH")"
    touch "$PRISM_APPIMAGE_PATH" && chmod +x "$PRISM_APPIMAGE_PATH"

    configure_launcher_paths

    [ "$CREATION_LAUNCHER"      = "prismlauncher" ]
    [ "$CREATION_LAUNCHER_TYPE" = "appimage" ]
    [ "$ACTIVE_LAUNCHER"        = "prismlauncher" ]
    [ "$ACTIVE_LAUNCHER_TYPE"   = "appimage" ]
    [ "$ACTIVE_LAUNCHER_SCRIPT" = "$PRISM_APPIMAGE_DATA_DIR/minecraftSplitscreen.sh" ]
}
