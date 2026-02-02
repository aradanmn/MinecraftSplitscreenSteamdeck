#!/bin/bash
# =============================================================================
# PATH CONFIGURATION MODULE - SINGLE SOURCE OF TRUTH
# =============================================================================
# @file        path_configuration.sh
# @version     3.0.0
# @date        2026-02-01
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Centralizes ALL path definitions and launcher detection for the Minecraft
#   Splitscreen installer. All other modules MUST use these variables and
#   functions - DO NOT hardcode paths anywhere else.
#
#   This module manages two launcher configurations:
#   - CREATION launcher: Used for CLI instance creation (PrismLauncher preferred)
#   - ACTIVE launcher: Used for gameplay (PollyMC preferred if available)
#
# @dependencies
#   - flatpak (optional, for Flatpak detection)
#   - utilities.sh (for print_* functions, should_prefer_flatpak)
#
# @exports
#   Constants:
#     - PRISM_FLATPAK_ID          : PrismLauncher Flatpak application ID
#     - POLLYMC_FLATPAK_ID        : PollyMC Flatpak application ID
#     - PRISM_APPIMAGE_DATA_DIR   : PrismLauncher AppImage data directory
#     - POLLYMC_APPIMAGE_DATA_DIR : PollyMC AppImage data directory
#     - PRISM_FLATPAK_DATA_DIR    : PrismLauncher Flatpak data directory
#     - POLLYMC_FLATPAK_DATA_DIR  : PollyMC Flatpak data directory
#     - PRISM_APPIMAGE_PATH       : Path to PrismLauncher AppImage
#     - POLLYMC_APPIMAGE_PATH     : Path to PollyMC AppImage
#
#   Variables (set by configure_launcher_paths):
#     - PREFER_FLATPAK            : Whether to prefer Flatpak over AppImage (true/false)
#     - IMMUTABLE_OS_DETECTED     : Whether running on immutable OS (true/false)
#     - ACTIVE_LAUNCHER           : Active launcher name ("prismlauncher"/"pollymc")
#     - ACTIVE_LAUNCHER_TYPE      : Active launcher type ("appimage"/"flatpak")
#     - ACTIVE_DATA_DIR           : Active launcher data directory
#     - ACTIVE_INSTANCES_DIR      : Active launcher instances directory
#     - ACTIVE_EXECUTABLE         : Command to run active launcher
#     - ACTIVE_LAUNCHER_SCRIPT    : Path to minecraftSplitscreen.sh
#     - CREATION_LAUNCHER         : Creation launcher name
#     - CREATION_LAUNCHER_TYPE    : Creation launcher type
#     - CREATION_DATA_DIR         : Creation launcher data directory
#     - CREATION_INSTANCES_DIR    : Creation launcher instances directory
#     - CREATION_EXECUTABLE       : Command to run creation launcher
#
#   Functions:
#     - is_flatpak_installed            : Check if Flatpak app is installed
#     - is_appimage_available           : Check if AppImage exists
#     - detect_prismlauncher            : Detect PrismLauncher installation
#     - detect_pollymc                  : Detect PollyMC installation
#     - configure_launcher_paths        : Main configuration function
#     - set_creation_launcher_prismlauncher : Set PrismLauncher as creation launcher
#     - set_active_launcher_pollymc     : Set PollyMC as active launcher
#     - revert_to_prismlauncher         : Revert active launcher to PrismLauncher
#     - finalize_launcher_paths         : Finalize and verify configuration
#     - get_creation_instances_dir      : Get creation instances directory
#     - get_active_instances_dir        : Get active instances directory
#     - get_launcher_script_path        : Get launcher script path
#     - get_active_executable           : Get active launcher executable
#     - get_active_data_dir             : Get active data directory
#     - needs_instance_migration        : Check if migration needed
#     - get_migration_source_dir        : Get migration source directory
#     - get_migration_dest_dir          : Get migration destination directory
#     - validate_path_configuration     : Validate all paths are set
#     - print_path_configuration        : Debug print all paths
#
# @changelog
#   2.1.0 (2026-01-31) - Added architecture detection for PollyMC AppImage (x86_64/arm64)
#   2.0.2 (2026-01-25) - Fix: Don't create directories in configure_launcher_paths() detection phase
#   2.0.1 (2026-01-25) - Centralized PREFER_FLATPAK decision; set once, used by all modules
#   2.0.0 (2026-01-25) - Rebased to 2.x for fork; added comprehensive JSDoc documentation
#   1.1.1 (2026-01-25) - Prefer Flatpak over AppImage on immutable OS (Bazzite, SteamOS, etc.)
#   1.1.0 (2026-01-24) - Added revert_to_prismlauncher function
#   1.0.0 (2026-01-23) - Initial version with centralized path management
# =============================================================================

# =============================================================================
# LAUNCHER IDENTIFIERS (Constants)
# =============================================================================
readonly PRISM_FLATPAK_ID="org.prismlauncher.PrismLauncher"
readonly POLLYMC_FLATPAK_ID="org.fn2006.PollyMC"

# =============================================================================
# BASE PATH DEFINITIONS (Constants)
# =============================================================================
# AppImage data directories (where AppImage launchers store their data)
readonly PRISM_APPIMAGE_DATA_DIR="$HOME/.local/share/PrismLauncher"
readonly POLLYMC_APPIMAGE_DATA_DIR="$HOME/.local/share/PollyMC"

# Flatpak data directories (where Flatpak launchers store their data)
readonly PRISM_FLATPAK_DATA_DIR="$HOME/.var/app/${PRISM_FLATPAK_ID}/data/PrismLauncher"
readonly POLLYMC_FLATPAK_DATA_DIR="$HOME/.var/app/${POLLYMC_FLATPAK_ID}/data/PollyMC"

# Detect system architecture for AppImage filenames
# Maps uname -m output to PollyMC release naming convention
_SYSTEM_ARCH=$(uname -m)
case "$_SYSTEM_ARCH" in
    x86_64)
        _POLLYMC_ARCH_SUFFIX="x86_64"
        ;;
    aarch64|arm64)
        _POLLYMC_ARCH_SUFFIX="arm64"
        ;;
    *)
        # Fallback to x86_64 for unknown architectures
        _POLLYMC_ARCH_SUFFIX="x86_64"
        ;;
esac

# AppImage executable locations
readonly PRISM_APPIMAGE_PATH="$PRISM_APPIMAGE_DATA_DIR/PrismLauncher.AppImage"
readonly POLLYMC_APPIMAGE_PATH="$POLLYMC_APPIMAGE_DATA_DIR/PollyMC-Linux-${_POLLYMC_ARCH_SUFFIX}.AppImage"

# =============================================================================
# SYSTEM DETECTION VARIABLES
# =============================================================================
# These are set once by configure_launcher_paths() and used by all modules

# Whether to prefer Flatpak installations over AppImage
# Set based on OS type detection (immutable OS = prefer Flatpak)
PREFER_FLATPAK=false

# Whether an immutable OS was detected
IMMUTABLE_OS_DETECTED=false

# =============================================================================
# ACTIVE CONFIGURATION VARIABLES
# =============================================================================
# These are set by configure_launcher_paths() based on what's detected

# Primary launcher (the one used for gameplay)
ACTIVE_LAUNCHER=""           # "prismlauncher" or "pollymc"
ACTIVE_LAUNCHER_TYPE=""      # "appimage" or "flatpak"
ACTIVE_DATA_DIR=""           # Where launcher stores its data
ACTIVE_INSTANCES_DIR=""      # Where instances are stored
ACTIVE_EXECUTABLE=""         # Command to run the launcher
ACTIVE_LAUNCHER_SCRIPT=""    # Path to minecraftSplitscreen.sh

# Creation launcher (used for initial instance creation, may differ from primary)
CREATION_LAUNCHER=""         # "prismlauncher" or "pollymc"
CREATION_LAUNCHER_TYPE=""    # "appimage" or "flatpak"
CREATION_DATA_DIR=""         # Where to create instances
CREATION_INSTANCES_DIR=""    # Instance creation directory
CREATION_EXECUTABLE=""       # Command to run creation launcher

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    is_flatpak_installed
# @description Checks if a Flatpak application is installed on the system.
# @param       $1 - Flatpak application ID (e.g., "org.prismlauncher.PrismLauncher")
# @return      0 if installed, 1 if not installed or flatpak unavailable
# @example
#   if is_flatpak_installed "org.prismlauncher.PrismLauncher"; then
#       echo "PrismLauncher Flatpak is installed"
#   fi
# -----------------------------------------------------------------------------
is_flatpak_installed() {
    local flatpak_id="$1"
    command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q "$flatpak_id"
}

# -----------------------------------------------------------------------------
# @function    is_appimage_available
# @description Checks if an AppImage file exists and is executable.
# @param       $1 - Full path to the AppImage file
# @return      0 if exists and executable, 1 otherwise
# @example
#   if is_appimage_available "$HOME/.local/share/PrismLauncher/PrismLauncher.AppImage"; then
#       echo "AppImage is ready to use"
#   fi
# -----------------------------------------------------------------------------
is_appimage_available() {
    local appimage_path="$1"
    [[ -f "$appimage_path" ]] && [[ -x "$appimage_path" ]]
}

# -----------------------------------------------------------------------------
# @function    detect_prismlauncher
# @description Detects if PrismLauncher is installed (AppImage or Flatpak).
#              Sets PRISM_TYPE, PRISM_DATA_DIR, and PRISM_EXECUTABLE variables.
#              Uses PREFER_FLATPAK (set by configure_launcher_paths) to determine
#              check order: Flatpak first on immutable OS, AppImage first otherwise.
# @param       None
# @global      PREFER_FLATPAK   - (input) Whether to prefer Flatpak
# @global      PRISM_DETECTED   - (output) Set to true/false
# @global      PRISM_TYPE       - (output) "appimage" or "flatpak"
# @global      PRISM_DATA_DIR   - (output) Path to data directory
# @global      PRISM_EXECUTABLE - (output) Command to run PrismLauncher
# @return      0 if detected, 1 if not found
# -----------------------------------------------------------------------------
detect_prismlauncher() {
    PRISM_DETECTED=false
    PRISM_TYPE=""
    PRISM_DATA_DIR=""
    PRISM_EXECUTABLE=""

    # Check order depends on PREFER_FLATPAK (set during system detection)
    if [[ "$PREFER_FLATPAK" == true ]]; then
        # Immutable OS: Check Flatpak first, then AppImage
        if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
            PRISM_TYPE="flatpak"
            PRISM_DATA_DIR="$PRISM_FLATPAK_DATA_DIR"
            PRISM_EXECUTABLE="flatpak run $PRISM_FLATPAK_ID"
            print_info "Detected Flatpak PrismLauncher (preferred)"
            return 0
        fi

        if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
            PRISM_TYPE="appimage"
            PRISM_DATA_DIR="$PRISM_APPIMAGE_DATA_DIR"
            PRISM_EXECUTABLE="$PRISM_APPIMAGE_PATH"
            print_info "Detected AppImage PrismLauncher (fallback)"
            return 0
        fi
    else
        # Traditional OS: Check AppImage first, then Flatpak
        if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
            PRISM_TYPE="appimage"
            PRISM_DATA_DIR="$PRISM_APPIMAGE_DATA_DIR"
            PRISM_EXECUTABLE="$PRISM_APPIMAGE_PATH"
            print_info "Detected AppImage PrismLauncher (preferred)"
            return 0
        fi

        if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
            PRISM_TYPE="flatpak"
            PRISM_DATA_DIR="$PRISM_FLATPAK_DATA_DIR"
            PRISM_EXECUTABLE="flatpak run $PRISM_FLATPAK_ID"
            print_info "Detected Flatpak PrismLauncher (fallback)"
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# @function    detect_pollymc
# @description Detects if PollyMC is installed (AppImage or Flatpak).
#              Sets POLLYMC_TYPE, POLLYMC_DATA_DIR, and POLLYMC_EXECUTABLE.
#              Uses PREFER_FLATPAK (set by configure_launcher_paths) to determine
#              check order: Flatpak first on immutable OS, AppImage first otherwise.
# @param       None
# @global      PREFER_FLATPAK     - (input) Whether to prefer Flatpak
# @global      POLLYMC_DETECTED   - (output) Set to true/false
# @global      POLLYMC_TYPE       - (output) "appimage" or "flatpak"
# @global      POLLYMC_DATA_DIR   - (output) Path to data directory
# @global      POLLYMC_EXECUTABLE - (output) Command to run PollyMC
# @return      0 if detected, 1 if not found
# -----------------------------------------------------------------------------
detect_pollymc() {
    POLLYMC_DETECTED=false
    POLLYMC_TYPE=""
    POLLYMC_DATA_DIR=""
    POLLYMC_EXECUTABLE=""

    # Check order depends on PREFER_FLATPAK (set during system detection)
    if [[ "$PREFER_FLATPAK" == true ]]; then
        # Immutable OS: Check Flatpak first, then AppImage
        if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
            POLLYMC_TYPE="flatpak"
            POLLYMC_DATA_DIR="$POLLYMC_FLATPAK_DATA_DIR"
            POLLYMC_EXECUTABLE="flatpak run $POLLYMC_FLATPAK_ID"
            print_info "Detected Flatpak PollyMC (preferred)"
            return 0
        fi

        if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
            POLLYMC_TYPE="appimage"
            POLLYMC_DATA_DIR="$POLLYMC_APPIMAGE_DATA_DIR"
            POLLYMC_EXECUTABLE="$POLLYMC_APPIMAGE_PATH"
            print_info "Detected AppImage PollyMC (fallback)"
            return 0
        fi
    else
        # Traditional OS: Check AppImage first, then Flatpak
        if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
            POLLYMC_TYPE="appimage"
            POLLYMC_DATA_DIR="$POLLYMC_APPIMAGE_DATA_DIR"
            POLLYMC_EXECUTABLE="$POLLYMC_APPIMAGE_PATH"
            print_info "Detected AppImage PollyMC (preferred)"
            return 0
        fi

        if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
            POLLYMC_TYPE="flatpak"
            POLLYMC_DATA_DIR="$POLLYMC_FLATPAK_DATA_DIR"
            POLLYMC_EXECUTABLE="flatpak run $POLLYMC_FLATPAK_ID"
            print_info "Detected Flatpak PollyMC (fallback)"
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# MAIN CONFIGURATION FUNCTION
# =============================================================================

# -----------------------------------------------------------------------------
# @function    configure_launcher_paths
# @description Main configuration function that detects installed launchers
#              and sets up CREATION_* and ACTIVE_* variables. This MUST be
#              called early in the installation process before any other
#              module tries to access launcher paths.
#
#              Priority:
#              - Creation launcher: PrismLauncher (has CLI support)
#              - Active launcher: PollyMC if available, else PrismLauncher
#
# @param       None
# @global      All CREATION_* and ACTIVE_* variables are set
# @return      0 always
# -----------------------------------------------------------------------------
configure_launcher_paths() {
    print_header "DETECTING LAUNCHER CONFIGURATION"

    # =========================================================================
    # SYSTEM TYPE DETECTION (MUST BE FIRST)
    # =========================================================================
    # Detect if we're on an immutable OS and set PREFER_FLATPAK accordingly.
    # This decision is made ONCE here and used by all subsequent modules.

    if is_immutable_os; then
        IMMUTABLE_OS_DETECTED=true
        PREFER_FLATPAK=true
        print_info "Detected immutable OS: ${IMMUTABLE_OS_NAME:-unknown}"
        print_info "Flatpak installations will be preferred over AppImage"
    else
        IMMUTABLE_OS_DETECTED=false
        PREFER_FLATPAK=false
        print_info "Traditional Linux system detected"
        print_info "AppImage installations will be preferred"
    fi

    # =========================================================================
    # LAUNCHER DETECTION
    # =========================================================================

    # Determine creation launcher (PrismLauncher preferred for CLI instance creation)
    if detect_prismlauncher; then
        CREATION_LAUNCHER="prismlauncher"
        CREATION_LAUNCHER_TYPE="$PRISM_TYPE"
        CREATION_DATA_DIR="$PRISM_DATA_DIR"
        CREATION_INSTANCES_DIR="$PRISM_DATA_DIR/instances"
        CREATION_EXECUTABLE="$PRISM_EXECUTABLE"
        print_success "Creation launcher: PrismLauncher ($PRISM_TYPE)"
        print_info "  Data directory: $CREATION_DATA_DIR"
        print_info "  Instances: $CREATION_INSTANCES_DIR"
    else
        # No PrismLauncher - will need to download or use PollyMC
        CREATION_LAUNCHER=""
        print_warning "No PrismLauncher detected - will attempt download"
    fi

    # Determine active/gameplay launcher (PollyMC preferred if available)
    if detect_pollymc; then
        ACTIVE_LAUNCHER="pollymc"
        ACTIVE_LAUNCHER_TYPE="$POLLYMC_TYPE"
        ACTIVE_DATA_DIR="$POLLYMC_DATA_DIR"
        ACTIVE_INSTANCES_DIR="$POLLYMC_DATA_DIR/instances"
        ACTIVE_EXECUTABLE="$POLLYMC_EXECUTABLE"
        ACTIVE_LAUNCHER_SCRIPT="$POLLYMC_DATA_DIR/minecraftSplitscreen.sh"
        print_success "Active launcher: PollyMC ($POLLYMC_TYPE)"
        print_info "  Data directory: $ACTIVE_DATA_DIR"
        print_info "  Launcher script: $ACTIVE_LAUNCHER_SCRIPT"
    elif detect_prismlauncher; then
        ACTIVE_LAUNCHER="prismlauncher"
        ACTIVE_LAUNCHER_TYPE="$PRISM_TYPE"
        ACTIVE_DATA_DIR="$PRISM_DATA_DIR"
        ACTIVE_INSTANCES_DIR="$PRISM_DATA_DIR/instances"
        ACTIVE_EXECUTABLE="$PRISM_EXECUTABLE"
        ACTIVE_LAUNCHER_SCRIPT="$PRISM_DATA_DIR/minecraftSplitscreen.sh"
        print_success "Active launcher: PrismLauncher ($PRISM_TYPE)"
        print_info "  Data directory: $ACTIVE_DATA_DIR"
        print_info "  Launcher script: $ACTIVE_LAUNCHER_SCRIPT"
    else
        print_warning "No launcher detected - will configure after download"
    fi

    # NOTE: Directories are NOT created here during detection phase.
    # They are created later by launcher_setup.sh and pollymc_setup.sh
    # only after successful installation/download to avoid empty directories.
}

# =============================================================================
# POST-DOWNLOAD CONFIGURATION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    set_creation_launcher_prismlauncher
# @description Updates the creation launcher configuration after PrismLauncher
#              is downloaded or installed. Also sets ACTIVE_* variables if no
#              active launcher is configured yet.
# @param       $1 - type: "appimage" or "flatpak"
# @param       $2 - executable: Path or command to run PrismLauncher
# @global      CREATION_* variables are updated
# @global      ACTIVE_* variables may be updated if not set
# @return      0 always
# -----------------------------------------------------------------------------
set_creation_launcher_prismlauncher() {
    local type="$1"
    local executable="$2"

    CREATION_LAUNCHER="prismlauncher"
    CREATION_LAUNCHER_TYPE="$type"

    if [[ "$type" == "appimage" ]]; then
        CREATION_DATA_DIR="$PRISM_APPIMAGE_DATA_DIR"
    else
        CREATION_DATA_DIR="$PRISM_FLATPAK_DATA_DIR"
    fi

    CREATION_INSTANCES_DIR="$CREATION_DATA_DIR/instances"
    CREATION_EXECUTABLE="$executable"

    mkdir -p "$CREATION_INSTANCES_DIR"

    # If no active launcher set yet, use PrismLauncher
    if [[ -z "$ACTIVE_LAUNCHER" ]]; then
        ACTIVE_LAUNCHER="prismlauncher"
        ACTIVE_LAUNCHER_TYPE="$type"
        ACTIVE_DATA_DIR="$CREATION_DATA_DIR"
        ACTIVE_INSTANCES_DIR="$CREATION_INSTANCES_DIR"
        ACTIVE_EXECUTABLE="$executable"
        ACTIVE_LAUNCHER_SCRIPT="$ACTIVE_DATA_DIR/minecraftSplitscreen.sh"
    fi
}

# -----------------------------------------------------------------------------
# @function    set_active_launcher_pollymc
# @description Updates the active launcher configuration to use PollyMC
#              after it has been downloaded or detected.
# @param       $1 - type: "appimage" or "flatpak"
# @param       $2 - executable: Path or command to run PollyMC
# @global      ACTIVE_* variables are updated
# @return      0 always
# -----------------------------------------------------------------------------
set_active_launcher_pollymc() {
    local type="$1"
    local executable="$2"

    ACTIVE_LAUNCHER="pollymc"
    ACTIVE_LAUNCHER_TYPE="$type"

    if [[ "$type" == "appimage" ]]; then
        ACTIVE_DATA_DIR="$POLLYMC_APPIMAGE_DATA_DIR"
    else
        ACTIVE_DATA_DIR="$POLLYMC_FLATPAK_DATA_DIR"
    fi

    ACTIVE_INSTANCES_DIR="$ACTIVE_DATA_DIR/instances"
    ACTIVE_EXECUTABLE="$executable"
    ACTIVE_LAUNCHER_SCRIPT="$ACTIVE_DATA_DIR/minecraftSplitscreen.sh"

    mkdir -p "$ACTIVE_INSTANCES_DIR"
}

# -----------------------------------------------------------------------------
# @function    revert_to_prismlauncher
# @description Reverts the active launcher back to PrismLauncher. Called when
#              PollyMC setup fails and we need to fall back to PrismLauncher
#              for gameplay.
# @param       None
# @global      ACTIVE_* variables are reset to match CREATION_* values
# @return      0 always
# -----------------------------------------------------------------------------
revert_to_prismlauncher() {
    print_info "Reverting to PrismLauncher as active launcher..."

    ACTIVE_LAUNCHER="prismlauncher"
    ACTIVE_LAUNCHER_TYPE="$CREATION_LAUNCHER_TYPE"
    ACTIVE_DATA_DIR="$CREATION_DATA_DIR"
    ACTIVE_INSTANCES_DIR="$CREATION_INSTANCES_DIR"
    ACTIVE_EXECUTABLE="$CREATION_EXECUTABLE"
    ACTIVE_LAUNCHER_SCRIPT="$ACTIVE_DATA_DIR/minecraftSplitscreen.sh"

    print_success "Active launcher reverted to PrismLauncher ($ACTIVE_LAUNCHER_TYPE)"
    print_info "  Data directory: $ACTIVE_DATA_DIR"
    print_info "  Instances: $ACTIVE_INSTANCES_DIR"
}

# -----------------------------------------------------------------------------
# @function    finalize_launcher_paths
# @description Finalizes path configuration after all downloads and setup
#              are complete. Verifies that instances exist in the expected
#              location and falls back to PrismLauncher if PollyMC migration
#              failed.
# @param       None
# @global      ACTIVE_* variables may be updated if verification fails
# @return      0 always
# -----------------------------------------------------------------------------
finalize_launcher_paths() {
    print_info "Finalizing launcher configuration..."

    # If we're using PollyMC as active but instances were created in PrismLauncher,
    # they should have been migrated. Verify.
    if [[ "$ACTIVE_LAUNCHER" == "pollymc" ]] && [[ "$CREATION_LAUNCHER" == "prismlauncher" ]]; then
        if [[ -d "$ACTIVE_INSTANCES_DIR/latestUpdate-1" ]]; then
            print_success "Instances verified in PollyMC directory"
        else
            print_warning "Instances not found in PollyMC, falling back to PrismLauncher"
            ACTIVE_LAUNCHER="prismlauncher"
            ACTIVE_LAUNCHER_TYPE="$CREATION_LAUNCHER_TYPE"
            ACTIVE_DATA_DIR="$CREATION_DATA_DIR"
            ACTIVE_INSTANCES_DIR="$CREATION_INSTANCES_DIR"
            ACTIVE_EXECUTABLE="$CREATION_EXECUTABLE"
            ACTIVE_LAUNCHER_SCRIPT="$ACTIVE_DATA_DIR/minecraftSplitscreen.sh"
        fi
    fi

    print_success "Final configuration:"
    print_info "  Launcher: $ACTIVE_LAUNCHER ($ACTIVE_LAUNCHER_TYPE)"
    print_info "  Data: $ACTIVE_DATA_DIR"
    print_info "  Instances: $ACTIVE_INSTANCES_DIR"
    print_info "  Script: $ACTIVE_LAUNCHER_SCRIPT"
}

# =============================================================================
# PATH ACCESSOR FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    get_creation_instances_dir
# @description Returns the directory where instances should be created.
# @param       None
# @stdout      Path to creation instances directory
# @return      0 always
# -----------------------------------------------------------------------------
get_creation_instances_dir() {
    echo "$CREATION_INSTANCES_DIR"
}

# -----------------------------------------------------------------------------
# @function    get_active_instances_dir
# @description Returns the directory where instances are stored for gameplay.
# @param       None
# @stdout      Path to active instances directory
# @return      0 always
# -----------------------------------------------------------------------------
get_active_instances_dir() {
    echo "$ACTIVE_INSTANCES_DIR"
}

# -----------------------------------------------------------------------------
# @function    get_launcher_script_path
# @description Returns the path where minecraftSplitscreen.sh should be created.
# @param       None
# @stdout      Path to launcher script
# @return      0 always
# -----------------------------------------------------------------------------
get_launcher_script_path() {
    echo "$ACTIVE_LAUNCHER_SCRIPT"
}

# -----------------------------------------------------------------------------
# @function    get_active_executable
# @description Returns the command to run the active launcher.
# @param       None
# @stdout      Executable path or command
# @return      0 always
# -----------------------------------------------------------------------------
get_active_executable() {
    echo "$ACTIVE_EXECUTABLE"
}

# -----------------------------------------------------------------------------
# @function    get_active_data_dir
# @description Returns the active launcher's data directory.
# @param       None
# @stdout      Path to active data directory
# @return      0 always
# -----------------------------------------------------------------------------
get_active_data_dir() {
    echo "$ACTIVE_DATA_DIR"
}

# -----------------------------------------------------------------------------
# @function    needs_instance_migration
# @description Checks if instances need to be migrated from creation launcher
#              to active launcher (i.e., they are different launchers).
# @param       None
# @return      0 if migration needed, 1 if not needed
# -----------------------------------------------------------------------------
needs_instance_migration() {
    [[ "$CREATION_LAUNCHER" != "$ACTIVE_LAUNCHER" ]] || [[ "$CREATION_DATA_DIR" != "$ACTIVE_DATA_DIR" ]]
}

# -----------------------------------------------------------------------------
# @function    get_migration_source_dir
# @description Returns the source directory for instance migration.
# @param       None
# @stdout      Path to migration source (creation instances directory)
# @return      0 always
# -----------------------------------------------------------------------------
get_migration_source_dir() {
    echo "$CREATION_INSTANCES_DIR"
}

# -----------------------------------------------------------------------------
# @function    get_migration_dest_dir
# @description Returns the destination directory for instance migration.
# @param       None
# @stdout      Path to migration destination (active instances directory)
# @return      0 always
# -----------------------------------------------------------------------------
get_migration_dest_dir() {
    echo "$ACTIVE_INSTANCES_DIR"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    validate_path_configuration
# @description Validates that all required path variables are set. Used to
#              verify configuration is complete before proceeding.
# @param       None
# @stderr      Error messages for missing variables
# @return      Number of errors (0 if all valid)
# -----------------------------------------------------------------------------
validate_path_configuration() {
    local errors=0

    if [[ -z "$ACTIVE_DATA_DIR" ]]; then
        print_error "ACTIVE_DATA_DIR not set"
        ((errors++))
    elif [[ ! -d "$ACTIVE_DATA_DIR" ]]; then
        print_warning "ACTIVE_DATA_DIR does not exist: $ACTIVE_DATA_DIR"
    fi

    if [[ -z "$ACTIVE_INSTANCES_DIR" ]]; then
        print_error "ACTIVE_INSTANCES_DIR not set"
        ((errors++))
    fi

    if [[ -z "$ACTIVE_LAUNCHER_SCRIPT" ]]; then
        print_error "ACTIVE_LAUNCHER_SCRIPT not set"
        ((errors++))
    fi

    if [[ -z "$ACTIVE_EXECUTABLE" ]]; then
        print_error "ACTIVE_EXECUTABLE not set"
        ((errors++))
    fi

    return $errors
}

# -----------------------------------------------------------------------------
# @function    print_path_configuration
# @description Prints all path configuration variables for debugging purposes.
# @param       None
# @stdout      Formatted configuration dump
# @return      0 always
# -----------------------------------------------------------------------------
print_path_configuration() {
    echo "=== PATH CONFIGURATION ==="
    echo "Creation Launcher: $CREATION_LAUNCHER ($CREATION_LAUNCHER_TYPE)"
    echo "Creation Data Dir: $CREATION_DATA_DIR"
    echo "Creation Instances: $CREATION_INSTANCES_DIR"
    echo "Creation Executable: $CREATION_EXECUTABLE"
    echo ""
    echo "Active Launcher: $ACTIVE_LAUNCHER ($ACTIVE_LAUNCHER_TYPE)"
    echo "Active Data Dir: $ACTIVE_DATA_DIR"
    echo "Active Instances: $ACTIVE_INSTANCES_DIR"
    echo "Active Executable: $ACTIVE_EXECUTABLE"
    echo "Launcher Script: $ACTIVE_LAUNCHER_SCRIPT"
    echo "=========================="
}
