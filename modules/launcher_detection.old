#!/bin/bash
# =============================================================================
# Launcher Detection & Path Configuration Module
# =============================================================================

# =============================================================================
# Constants (The "Source of Truth" for Paths)
# =============================================================================
readonly LAUNCHER_TYPE_APPIMAGE="appimage"
readonly LAUNCHER_TYPE_FLATPAK="flatpak"
readonly LAUNCHER_TYPE_NONE="none"

# PollyMC paths
readonly POLLYMC_NAME="PollyMC"
readonly POLLYMC_APPIMAGE_DIR="$HOME/.local/share/PollyMC"
readonly POLLYMC_APPIMAGE_PATH="${POLLYMC_APPIMAGE_DIR}/PollyMC-Linux-x86_64.AppImage"
readonly POLLYMC_FLATPAK_ID="org.fn2006.PollyMC"
readonly POLLYMC_FLATPAK_DATA_DIR="$HOME/.var/app/${POLLYMC_FLATPAK_ID}/data/PollyMC"

# PrismLauncher paths
readonly PRISM_NAME="PrismLauncher"
readonly PRISM_APPIMAGE_DIR="$HOME/.local/share/PrismLauncher"
readonly PRISM_APPIMAGE_PATH="${PRISM_APPIMAGE_DIR}/PrismLauncher.AppImage"
readonly PRISM_FLATPAK_ID="org.prismlauncher.PrismLauncher"
readonly PRISM_FLATPAK_DATA_DIR="$HOME/.var/app/${PRISM_FLATPAK_ID}/data/PrismLauncher"

# =============================================================================
# Global State (Configured at Runtime)
# =============================================================================

# Creation Launcher (PrismLauncher - used for its CLI capabilities)
CREATION_LAUNCHER_TYPE=""
CREATION_EXECUTABLE=""
CREATION_DATA_DIR=""
CREATION_INSTANCES_DIR=""

# Active Launcher (PollyMC - used for the final splitscreen gameplay)
ACTIVE_LAUNCHER_NAME=""
ACTIVE_LAUNCHER_TYPE=""
ACTIVE_LAUNCHER_EXEC=""
ACTIVE_LAUNCHER_DIR=""
ACTIVE_INSTANCES_DIR=""
ACTIVE_LAUNCHER_SCRIPT="$HOME/Desktop/minecraftSplitscreen.sh"

# Internal detection results
DETECTED_LAUNCHER_NAME=""
DETECTED_LAUNCHER_TYPE=""
DETECTED_LAUNCHER_EXEC=""
DETECTED_LAUNCHER_DIR=""

# =============================================================================
# Detection Functions
# =============================================================================

is_flatpak_installed() {
    flatpak info "$1" >/dev/null 2>&1
}

is_appimage_available() {
    [[ -f "$1" && -x "$1" ]]
}

# Sets the variables for the creation process (PrismLauncher)
set_creation_paths() {
    local type="$1"
    local exec="$2"

    CREATION_LAUNCHER_TYPE="$type"
    CREATION_EXECUTABLE="$exec"

    if [[ "$type" == "$LAUNCHER_TYPE_FLATPAK" ]]; then
        CREATION_DATA_DIR="$PRISM_FLATPAK_DATA_DIR"
    else
        CREATION_DATA_DIR="$PRISM_APPIMAGE_DIR"
    fi
    CREATION_INSTANCES_DIR="${CREATION_DATA_DIR}/instances"
}

# Configures the active gameplay variables based on detected PollyMC
configure_active_launcher() {
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        ACTIVE_LAUNCHER_NAME="$POLLYMC_NAME"
        ACTIVE_LAUNCHER_TYPE="$LAUNCHER_TYPE_FLATPAK"
        ACTIVE_LAUNCHER_EXEC="flatpak run $POLLYMC_FLATPAK_ID"
        ACTIVE_LAUNCHER_DIR="$POLLYMC_FLATPAK_DATA_DIR"
    elif is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
        ACTIVE_LAUNCHER_NAME="$POLLYMC_NAME"
        ACTIVE_LAUNCHER_TYPE="$LAUNCHER_TYPE_APPIMAGE"
        ACTIVE_LAUNCHER_EXEC="$POLLYMC_APPIMAGE_PATH"
        ACTIVE_LAUNCHER_DIR="$POLLYMC_APPIMAGE_DIR"
    else
        # Fallback to whatever was detected if PollyMC isn't found
        ACTIVE_LAUNCHER_NAME="$DETECTED_LAUNCHER_NAME"
        ACTIVE_LAUNCHER_TYPE="$DETECTED_LAUNCHER_TYPE"
        ACTIVE_LAUNCHER_EXEC="$DETECTED_LAUNCHER_EXEC"
        ACTIVE_LAUNCHER_DIR="$DETECTED_LAUNCHER_DIR"
    fi
    ACTIVE_INSTANCES_DIR="${ACTIVE_LAUNCHER_DIR}/instances"
}

# Main orchestration function called by main_workflow.sh
configure_launcher_paths() {
    print_progress "Configuring launcher paths..."

    # 1. Detect what's on the system
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        DETECTED_LAUNCHER_NAME="$POLLYMC_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_FLATPAK"
        DETECTED_LAUNCHER_EXEC="flatpak run $POLLYMC_FLATPAK_ID"
        DETECTED_LAUNCHER_DIR="$POLLYMC_FLATPAK_DATA_DIR"
    elif is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        DETECTED_LAUNCHER_NAME="$PRISM_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_FLATPAK"
        DETECTED_LAUNCHER_EXEC="flatpak run $PRISM_FLATPAK_ID"
        DETECTED_LAUNCHER_DIR="$PRISM_FLATPAK_DATA_DIR"
    fi

    # 2. Setup Active launcher (prefer PollyMC for gameplay)
    configure_active_launcher

    # 3. Initialize Creation launcher (will be refined by launcher_setup.sh)
    if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        set_creation_paths "$LAUNCHER_TYPE_FLATPAK" "flatpak run $PRISM_FLATPAK_ID"
    fi
}
