#!/bin/bash
# =============================================================================
# Launcher Detection Module
# =============================================================================
# Version: 2.0.0
# Last Modified: 2026-01-23
# Source: https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# This module handles detection of Minecraft launchers (PollyMC, PrismLauncher)
# in both AppImage and Flatpak formats. It auto-detects the best available
# launcher and provides consistent path information.
# =============================================================================

# =============================================================================
# Constants
# =============================================================================

# Launcher type identifiers
readonly LAUNCHER_TYPE_APPIMAGE="appimage"
readonly LAUNCHER_TYPE_FLATPAK="flatpak"
readonly LAUNCHER_TYPE_NONE="none"

# PollyMC paths and identifiers
readonly POLLYMC_NAME="PollyMC"
readonly POLLYMC_APPIMAGE_FILENAME="PollyMC-Linux-x86_64.AppImage"
readonly POLLYMC_APPIMAGE_DIR="$HOME/.local/share/PollyMC"
readonly POLLYMC_APPIMAGE_PATH="${POLLYMC_APPIMAGE_DIR}/${POLLYMC_APPIMAGE_FILENAME}"
readonly POLLYMC_FLATPAK_ID="org.fn2006.PollyMC"
readonly POLLYMC_FLATPAK_DATA_DIR="$HOME/.var/app/${POLLYMC_FLATPAK_ID}/data/PollyMC"

# PrismLauncher paths and identifiers
readonly PRISM_NAME="PrismLauncher"
readonly PRISM_APPIMAGE_FILENAME="PrismLauncher.AppImage"
readonly PRISM_APPIMAGE_DIR="$HOME/.local/share/PrismLauncher"
readonly PRISM_APPIMAGE_PATH="${PRISM_APPIMAGE_DIR}/${PRISM_APPIMAGE_FILENAME}"
readonly PRISM_FLATPAK_ID="org.prismlauncher.PrismLauncher"
readonly PRISM_FLATPAK_DATA_DIR="$HOME/.var/app/${PRISM_FLATPAK_ID}/data/PrismLauncher"

# =============================================================================
# Detection Variables (set by detection functions)
# =============================================================================

# These are populated by detect_* functions and used by other modules
DETECTED_LAUNCHER_NAME=""
DETECTED_LAUNCHER_TYPE=""
DETECTED_LAUNCHER_EXEC=""
DETECTED_LAUNCHER_DIR=""
DETECTED_INSTANCES_DIR=""

# =============================================================================
# Utility Functions
# =============================================================================

# Check if Flatpak is available on the system
is_flatpak_available() {
    command -v flatpak >/dev/null 2>&1
}

# Check if a specific Flatpak app is installed
# Arguments:
#   $1 = Flatpak app ID (e.g., "org.fn2006.PollyMC")
is_flatpak_installed() {
    local app_id="$1"

    if ! is_flatpak_available; then
        return 1
    fi

    flatpak list --app 2>/dev/null | grep -q "$app_id"
}

# Check if an AppImage exists and is executable
# Arguments:
#   $1 = Full path to AppImage
is_appimage_available() {
    local appimage_path="$1"

    [[ -f "$appimage_path" ]] && [[ -x "$appimage_path" ]]
}

# =============================================================================
# PollyMC Detection
# =============================================================================

# Detect PollyMC installation (AppImage or Flatpak)
# Sets DETECTED_* variables on success
# Returns 0 if found, 1 if not found
detect_pollymc() {
    # Priority 1: AppImage (preferred - more control, no sandboxing)
    if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
        DETECTED_LAUNCHER_NAME="$POLLYMC_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_APPIMAGE"
        DETECTED_LAUNCHER_EXEC="$POLLYMC_APPIMAGE_PATH"
        DETECTED_LAUNCHER_DIR="$POLLYMC_APPIMAGE_DIR"
        DETECTED_INSTANCES_DIR="${POLLYMC_APPIMAGE_DIR}/instances"
        return 0
    fi

    # Priority 2: Flatpak
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        DETECTED_LAUNCHER_NAME="$POLLYMC_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_FLATPAK"
        DETECTED_LAUNCHER_EXEC="flatpak run $POLLYMC_FLATPAK_ID"
        DETECTED_LAUNCHER_DIR="$POLLYMC_FLATPAK_DATA_DIR"
        DETECTED_INSTANCES_DIR="${POLLYMC_FLATPAK_DATA_DIR}/instances"
        return 0
    fi

    return 1
}

# Get PollyMC info without modifying global state
# Outputs: type|exec|data_dir|instances_dir
# Returns 1 if not found
get_pollymc_info() {
    if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
        echo "${LAUNCHER_TYPE_APPIMAGE}|${POLLYMC_APPIMAGE_PATH}|${POLLYMC_APPIMAGE_DIR}|${POLLYMC_APPIMAGE_DIR}/instances"
        return 0
    fi

    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        echo "${LAUNCHER_TYPE_FLATPAK}|flatpak run ${POLLYMC_FLATPAK_ID}|${POLLYMC_FLATPAK_DATA_DIR}|${POLLYMC_FLATPAK_DATA_DIR}/instances"
        return 0
    fi

    return 1
}

# =============================================================================
# PrismLauncher Detection
# =============================================================================

# Detect PrismLauncher installation (AppImage or Flatpak)
# Sets DETECTED_* variables on success
# Returns 0 if found, 1 if not found
detect_prismlauncher() {
    # Priority 1: AppImage
    if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
        DETECTED_LAUNCHER_NAME="$PRISM_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_APPIMAGE"
        DETECTED_LAUNCHER_EXEC="$PRISM_APPIMAGE_PATH"
        DETECTED_LAUNCHER_DIR="$PRISM_APPIMAGE_DIR"
        DETECTED_INSTANCES_DIR="${PRISM_APPIMAGE_DIR}/instances"
        return 0
    fi

    # Check for extracted AppImage (squashfs-root fallback)
    if [[ -x "${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun" ]]; then
        DETECTED_LAUNCHER_NAME="$PRISM_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_APPIMAGE"
        DETECTED_LAUNCHER_EXEC="${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun"
        DETECTED_LAUNCHER_DIR="$PRISM_APPIMAGE_DIR"
        DETECTED_INSTANCES_DIR="${PRISM_APPIMAGE_DIR}/instances"
        return 0
    fi

    # Priority 2: Flatpak
    if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        DETECTED_LAUNCHER_NAME="$PRISM_NAME"
        DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_FLATPAK"
        DETECTED_LAUNCHER_EXEC="flatpak run $PRISM_FLATPAK_ID"
        DETECTED_LAUNCHER_DIR="$PRISM_FLATPAK_DATA_DIR"
        DETECTED_INSTANCES_DIR="${PRISM_FLATPAK_DATA_DIR}/instances"
        return 0
    fi

    return 1
}

# Get PrismLauncher info without modifying global state
# Outputs: type|exec|data_dir|instances_dir
# Returns 1 if not found
get_prismlauncher_info() {
    if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
        echo "${LAUNCHER_TYPE_APPIMAGE}|${PRISM_APPIMAGE_PATH}|${PRISM_APPIMAGE_DIR}|${PRISM_APPIMAGE_DIR}/instances"
        return 0
    fi

    if [[ -x "${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun" ]]; then
        echo "${LAUNCHER_TYPE_APPIMAGE}|${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun|${PRISM_APPIMAGE_DIR}|${PRISM_APPIMAGE_DIR}/instances"
        return 0
    fi

    if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        echo "${LAUNCHER_TYPE_FLATPAK}|flatpak run ${PRISM_FLATPAK_ID}|${PRISM_FLATPAK_DATA_DIR}|${PRISM_FLATPAK_DATA_DIR}/instances"
        return 0
    fi

    return 1
}

# =============================================================================
# Combined Detection
# =============================================================================

# Detect the best available launcher for gameplay
# Priority: PollyMC > PrismLauncher (PollyMC is offline-friendly)
# Sets DETECTED_* variables on success
# Returns 0 if found, 1 if no launcher available
detect_gameplay_launcher() {
    # Prefer PollyMC for gameplay (offline-friendly, no forced auth)
    if detect_pollymc; then
        return 0
    fi

    # Fall back to PrismLauncher
    if detect_prismlauncher; then
        return 0
    fi

    # No launcher found
    DETECTED_LAUNCHER_NAME=""
    DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_NONE"
    DETECTED_LAUNCHER_EXEC=""
    DETECTED_LAUNCHER_DIR=""
    DETECTED_INSTANCES_DIR=""
    return 1
}

# Detect the best available launcher for installation
# Priority: PrismLauncher > PollyMC (PrismLauncher has better CLI)
# Sets DETECTED_* variables on success
# Returns 0 if found, 1 if no launcher available
detect_install_launcher() {
    # Prefer PrismLauncher for installation (better CLI support)
    if detect_prismlauncher; then
        return 0
    fi

    # Fall back to PollyMC
    if detect_pollymc; then
        return 0
    fi

    # No launcher found
    DETECTED_LAUNCHER_NAME=""
    DETECTED_LAUNCHER_TYPE="$LAUNCHER_TYPE_NONE"
    DETECTED_LAUNCHER_EXEC=""
    DETECTED_LAUNCHER_DIR=""
    DETECTED_INSTANCES_DIR=""
    return 1
}

# =============================================================================
# Path Helpers
# =============================================================================

# Get the data directory for a launcher type
# Arguments:
#   $1 = Launcher name ("PollyMC" or "PrismLauncher")
#   $2 = Launcher type ("appimage" or "flatpak")
get_launcher_data_dir() {
    local launcher_name="$1"
    local launcher_type="$2"

    case "$launcher_name" in
        "$POLLYMC_NAME")
            if [[ "$launcher_type" == "$LAUNCHER_TYPE_FLATPAK" ]]; then
                echo "$POLLYMC_FLATPAK_DATA_DIR"
            else
                echo "$POLLYMC_APPIMAGE_DIR"
            fi
            ;;
        "$PRISM_NAME")
            if [[ "$launcher_type" == "$LAUNCHER_TYPE_FLATPAK" ]]; then
                echo "$PRISM_FLATPAK_DATA_DIR"
            else
                echo "$PRISM_APPIMAGE_DIR"
            fi
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get the instances directory for a launcher
# Arguments:
#   $1 = Launcher name ("PollyMC" or "PrismLauncher")
#   $2 = Launcher type ("appimage" or "flatpak")
get_instances_dir() {
    local data_dir
    data_dir=$(get_launcher_data_dir "$1" "$2")

    if [[ -n "$data_dir" ]]; then
        echo "${data_dir}/instances"
    else
        return 1
    fi
}

# =============================================================================
# Status Reporting
# =============================================================================

# Print detection status for debugging
print_detection_status() {
    echo "=== Launcher Detection Status ==="
    echo ""

    echo "PollyMC:"
    if is_appimage_available "$POLLYMC_APPIMAGE_PATH"; then
        echo "  AppImage: FOUND at $POLLYMC_APPIMAGE_PATH"
    else
        echo "  AppImage: not found"
    fi
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID"; then
        echo "  Flatpak:  FOUND ($POLLYMC_FLATPAK_ID)"
    else
        echo "  Flatpak:  not installed"
    fi
    echo ""

    echo "PrismLauncher:"
    if is_appimage_available "$PRISM_APPIMAGE_PATH"; then
        echo "  AppImage: FOUND at $PRISM_APPIMAGE_PATH"
    elif [[ -x "${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun" ]]; then
        echo "  AppImage: FOUND (extracted) at ${PRISM_APPIMAGE_DIR}/squashfs-root/AppRun"
    else
        echo "  AppImage: not found"
    fi
    if is_flatpak_installed "$PRISM_FLATPAK_ID"; then
        echo "  Flatpak:  FOUND ($PRISM_FLATPAK_ID)"
    else
        echo "  Flatpak:  not installed"
    fi
    echo ""

    echo "Current Detection:"
    echo "  Name:      ${DETECTED_LAUNCHER_NAME:-<none>}"
    echo "  Type:      ${DETECTED_LAUNCHER_TYPE:-<none>}"
    echo "  Exec:      ${DETECTED_LAUNCHER_EXEC:-<none>}"
    echo "  Data Dir:  ${DETECTED_LAUNCHER_DIR:-<none>}"
    echo "  Instances: ${DETECTED_INSTANCES_DIR:-<none>}"
    echo "================================="
}
