#!/bin/bash
# =============================================================================
# Path Configuration Module - SINGLE SOURCE OF TRUTH
# =============================================================================
# This module centralizes ALL path definitions and launcher detection.
# All other modules MUST use these variables and functions.
# DO NOT hardcode paths anywhere else.
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

# AppImage executable locations
readonly PRISM_APPIMAGE_PATH="$PRISM_APPIMAGE_DATA_DIR/PrismLauncher.AppImage"
readonly POLLYMC_APPIMAGE_PATH="$POLLYMC_APPIMAGE_DATA_DIR/PollyMC-Linux-x86_64.AppImage"

# =============================================================================
# ACTIVE CONFIGURATION (Set by configure_launcher_paths)
# =============================================================================
# These are the ACTIVE paths that all modules should use
# They are set by configure_launcher_paths() based on what's detected

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

# Check if a Flatpak is installed
# Arguments: $1 = flatpak ID
# Returns: 0 if installed, 1 if not
is_flatpak_installed() {
    local flatpak_id="$1"
    command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q "$flatpak_id"
}

# Check if an AppImage exists and is executable
# Arguments: $1 = path to AppImage
# Returns: 0 if exists and executable, 1 if not
is_appimage_available() {
    local appimage_path="$1"
    [[ -f "$appimage_path" ]] && [[ -x "$appimage_path" ]]
}

# Detect PrismLauncher installation
# Sets: PRISM_DETECTED, PRISM_TYPE, PRISM_DATA_DIR, PRISM_EXECUTABLE
detect_prismlauncher() {
    PRISM_DETECTED=false
    PRISM_TYPE=""
    PRISM_DATA_DIR=""
    PRISM_EXECUTABLE=""

    # Check AppImage first (preferred for CLI capabilities)
    if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
        PRISM_DETECTED=true
        PRISM_TYPE="appimage"
        PRISM_DATA_DIR="$PRISM_APPIMAGE_DATA_DIR"
        PRISM_EXECUTABLE="$PRISM_APPIMAGE_PATH"
        return 0
    fi

    # Check Flatpak
    if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        PRISM_DETECTED=true
        PRISM_TYPE="flatpak"
        PRISM_DATA_DIR="$PRISM_FLATPAK_DATA_DIR"
        PRISM_EXECUTABLE="flatpak run $PRISM_FLATPAK_ID"
        return 0
    fi

    return 1
}

# Detect PollyMC installation
# Sets: POLLYMC_DETECTED, POLLYMC_TYPE, POLLYMC_DATA_DIR, POLLYMC_EXECUTABLE
detect_pollymc() {
    POLLYMC_DETECTED=false
    POLLYMC_TYPE=""
    POLLYMC_DATA_DIR=""
    POLLYMC_EXECUTABLE=""

    # Check AppImage first (preferred)
    if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
        POLLYMC_DETECTED=true
        POLLYMC_TYPE="appimage"
        POLLYMC_DATA_DIR="$POLLYMC_APPIMAGE_DATA_DIR"
        POLLYMC_EXECUTABLE="$POLLYMC_APPIMAGE_PATH"
        return 0
    fi

    # Check Flatpak
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        POLLYMC_DETECTED=true
        POLLYMC_TYPE="flatpak"
        POLLYMC_DATA_DIR="$POLLYMC_FLATPAK_DATA_DIR"
        POLLYMC_EXECUTABLE="flatpak run $POLLYMC_FLATPAK_ID"
        return 0
    fi

    return 1
}

# =============================================================================
# MAIN CONFIGURATION FUNCTION
# =============================================================================

# Configure all launcher paths based on detection
# This MUST be called early in the installation process
# It sets up both CREATION and ACTIVE launcher configurations
configure_launcher_paths() {
    print_header "DETECTING LAUNCHER CONFIGURATION"

    # Detect what's available
    detect_prismlauncher
    detect_pollymc

    # Determine creation launcher (PrismLauncher preferred for CLI instance creation)
    if [[ "$PRISM_DETECTED" == true ]]; then
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
    if [[ "$POLLYMC_DETECTED" == true ]]; then
        ACTIVE_LAUNCHER="pollymc"
        ACTIVE_LAUNCHER_TYPE="$POLLYMC_TYPE"
        ACTIVE_DATA_DIR="$POLLYMC_DATA_DIR"
        ACTIVE_INSTANCES_DIR="$POLLYMC_DATA_DIR/instances"
        ACTIVE_EXECUTABLE="$POLLYMC_EXECUTABLE"
        ACTIVE_LAUNCHER_SCRIPT="$POLLYMC_DATA_DIR/minecraftSplitscreen.sh"
        print_success "Active launcher: PollyMC ($POLLYMC_TYPE)"
        print_info "  Data directory: $ACTIVE_DATA_DIR"
        print_info "  Launcher script: $ACTIVE_LAUNCHER_SCRIPT"
    elif [[ "$PRISM_DETECTED" == true ]]; then
        # Fall back to PrismLauncher for gameplay too
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

    # Ensure directories exist
    if [[ -n "$CREATION_DATA_DIR" ]]; then
        mkdir -p "$CREATION_INSTANCES_DIR"
    fi
    if [[ -n "$ACTIVE_DATA_DIR" ]]; then
        mkdir -p "$ACTIVE_INSTANCES_DIR"
    fi
}

# =============================================================================
# POST-DOWNLOAD CONFIGURATION
# =============================================================================

# Update creation launcher after PrismLauncher is downloaded
# Arguments: $1 = type ("appimage" or "flatpak"), $2 = executable path/command
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

# Update active launcher after PollyMC is downloaded/configured
# Arguments: $1 = type ("appimage" or "flatpak"), $2 = executable path/command
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

# Finalize paths - call after all downloads/setup complete
# Ensures ACTIVE_* variables point to where instances actually are
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
# PATH ACCESSOR FUNCTIONS (Use these in other modules)
# =============================================================================

# Get the directory where instances should be created
get_creation_instances_dir() {
    echo "$CREATION_INSTANCES_DIR"
}

# Get the directory where instances are for gameplay
get_active_instances_dir() {
    echo "$ACTIVE_INSTANCES_DIR"
}

# Get the path for the launcher script
get_launcher_script_path() {
    echo "$ACTIVE_LAUNCHER_SCRIPT"
}

# Get the active launcher executable
get_active_executable() {
    echo "$ACTIVE_EXECUTABLE"
}

# Get the active data directory
get_active_data_dir() {
    echo "$ACTIVE_DATA_DIR"
}

# Check if we need to migrate instances from creation to active launcher
needs_instance_migration() {
    [[ "$CREATION_LAUNCHER" != "$ACTIVE_LAUNCHER" ]] || [[ "$CREATION_DATA_DIR" != "$ACTIVE_DATA_DIR" ]]
}

# Get source directory for instance migration
get_migration_source_dir() {
    echo "$CREATION_INSTANCES_DIR"
}

# Get destination directory for instance migration
get_migration_dest_dir() {
    echo "$ACTIVE_INSTANCES_DIR"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Validate that all required paths are configured
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

# Print current path configuration for debugging
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
