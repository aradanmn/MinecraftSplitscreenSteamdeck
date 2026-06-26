#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - MODULAR VERSION
# =============================================================================
# 
# This is the new, clean modular entry point for the Minecraft Splitscreen installer.
# All functionality has been moved to organized modules for better maintainability.
# Required modules are automatically downloaded as temporary files when the script runs.
#
# Features:
# - Automatic temporary module downloading (modules are cleaned up after completion)
# - Automatic Java detection and installation
# - Complete Fabric dependency chain implementation
# - API filtering for Fabric-compatible mods (Modrinth + CurseForge)
# - Enhanced error handling with multiple fallback mechanisms
# - User-friendly mod selection interface
# - Steam Deck optimized installation
# - Comprehensive Steam and desktop integration
#
# No additional setup, Java installation, token files, or module downloads required - just run this script.
# Modules are downloaded temporarily and automatically cleaned up when the script completes.
#
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Runtime flags
DEBUG_MODE=false

# Parse installer flags early so startup/module logs can respect debug mode.
declare -a FORWARDED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --debug)
            DEBUG_MODE=true
            ;;
        *)
            FORWARDED_ARGS+=("$arg")
            ;;
    esac
done
set -- "${FORWARDED_ARGS[@]}"

# =============================================================================
# CLEANUP AND SIGNAL HANDLING
# =============================================================================

# Global variable for modules directory (will be set later)
MODULES_DIR=""

# Cleanup function to remove temporary modules directory
cleanup() {
    if [[ -n "$MODULES_DIR" ]] && [[ -d "$MODULES_DIR" ]]; then
        echo "🧹 Cleaning up temporary modules..."
        rm -rf "$MODULES_DIR"
    fi
}

# Set up trap to cleanup on script exit (normal or error)
trap cleanup EXIT INT TERM

# =============================================================================
# MODULE DOWNLOADING AND LOADING
# =============================================================================

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Create a temporary directory for modules that will be cleaned up automatically
MODULES_DIR="$(mktemp -d -t minecraft-modules-XXXXXX)"

# Repo ref (branch/tag/commit) to install FROM. Defaults to 'main'; override to test a
# branch WITHOUT promoting it — e.g.:
#   REPO_REF=feat/gamescope-windowing ./install-minecraft-splitscreen.sh
# Exported so every sourced module's download URL uses the same ref.
export REPO_REF="${REPO_REF:-main}"

# GitHub repository information (modify these URLs to match your actual repository)
readonly REPO_BASE_URL="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/${REPO_REF}/modules"

# Installer modules — sourced during installation to run the setup workflow.
readonly INSTALLER_MODULE_FILES=(
    "utilities.sh"
    "java_management.sh"
    "launcher_setup.sh"
    "version_management.sh"
    "lwjgl_management.sh"
    "mod_management.sh"
    "instance_creation.sh"
    "steam_integration.sh"
    "desktop_launcher.sh"
    "main_workflow.sh"
)

# Runtime orchestrator modules — deployed to TARGET_DIR/modules/ so the launcher
# can source them at play time. NOT sourced by the installer.
readonly RUNTIME_MODULE_FILES=(
    "preflight.sh"
    "dock_detection.sh"
    "controller_monitor.sh"
    "kwin_positioner.sh"
    "window_manager.sh"
    "instance_lifecycle.sh"
    "watchdog.sh"
    "orchestrator.sh"
    "dex.sh"
)

# Combined list used by download_modules and the presence check below.
readonly MODULE_FILES=("${INSTALLER_MODULE_FILES[@]}" "${RUNTIME_MODULE_FILES[@]}")

# Function to download modules if they don't exist
download_modules() {
    echo "🔄 Downloading required modules to temporary directory..."
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "📁 Temporary modules directory: $MODULES_DIR"
        echo "🌐 Repository URL: $REPO_BASE_URL"
    fi
    
    # Temporarily disable strict error handling for downloads
    set +e
    
    # The temporary directory is already created by mktemp
    local downloaded_count=0
    local failed_count=0
    
    # Download each required module
    for module in "${MODULE_FILES[@]}"; do
        local module_path="$MODULES_DIR/$module"
        local module_url="$REPO_BASE_URL/$module"
        
        if [[ "$DEBUG_MODE" == true ]]; then
            echo "⬇️  Downloading module: $module"
            echo "    URL: $module_url"
        fi
        
        # Download the module file
        if command -v curl >/dev/null 2>&1; then
            curl_output=$(curl -fsSL "$module_url" -o "$module_path" 2>&1)
            curl_exit_code=$?
            if [[ $curl_exit_code -eq 0 ]]; then
                chmod +x "$module_path"
                ((downloaded_count++))
                if [[ "$DEBUG_MODE" == true ]]; then
                    echo "✅ Downloaded: $module"
                fi
            else
                echo "❌ Failed to download: $module"
                echo "    Curl exit code: $curl_exit_code"
                echo "    Error: $curl_output"
                ((failed_count++))
            fi
        elif command -v wget >/dev/null 2>&1; then
            wget_output=$(wget -q "$module_url" -O "$module_path" 2>&1)
            wget_exit_code=$?
            if [[ $wget_exit_code -eq 0 ]]; then
                chmod +x "$module_path"
                ((downloaded_count++))
                if [[ "$DEBUG_MODE" == true ]]; then
                    echo "✅ Downloaded: $module"
                fi
            else
                echo "❌ Failed to download: $module"
                echo "    Wget exit code: $wget_exit_code"
                echo "    Error: $wget_output"
                ((failed_count++))
            fi
        else
            echo "❌ Error: Neither curl nor wget is available"
            echo "Please install curl or wget to download modules automatically"
            echo "Or manually download all modules from: $REPO_BASE_URL"
            # Re-enable strict error handling before exiting
            set -euo pipefail
            exit 1
        fi
    done
    
    # Re-enable strict error handling
    set -euo pipefail
    
    if [[ $failed_count -gt 0 ]]; then
        echo "❌ Failed to download $failed_count module(s)"
        echo "ℹ️  This might be because:"
        echo "    - The repository doesn't exist or is private"
        echo "    - The modules haven't been uploaded to the repository yet"
        echo "    - Network connectivity issues"
        echo ""
        echo "🔧 For now, you can place the modules manually in the same directory as this script:"
        echo "    mkdir -p '$SCRIPT_DIR/modules'"
        echo "    # Then copy all .sh module files to that directory"
        echo ""
        echo "🌐 Or check if the repository exists at: https://github.com/aradanmn/MinecraftSplitscreenSteamdeck"
        exit 1
    fi
    
    echo "✅ Downloaded $downloaded_count module(s) to temporary directory"
    echo "ℹ️  Modules will be automatically cleaned up when script completes"
}

# Download modules if needed
# First check if modules exist locally, if not try to download them
if [[ -d "$SCRIPT_DIR/modules" ]]; then
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "📁 Found local modules directory, copying to temporary location..."
    fi
    cp -r "$SCRIPT_DIR/modules/"* "$MODULES_DIR/"
    chmod +x "$MODULES_DIR"/*.sh
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "✅ Copied local modules to temporary directory"
    fi
else
    download_modules
fi

# Verify all modules are now present
for module in "${MODULE_FILES[@]}"; do
    if [[ ! -f "$MODULES_DIR/$module" ]]; then
        echo "❌ Error: Required module missing: $module"
        echo "Please check your internet connection or download manually from:"
        echo "$REPO_BASE_URL/$module"
        exit 1
    fi
done

# Source installer modules to load their functions (dependency order).
# Runtime orchestrator modules (dock_detection, controller_monitor, etc.) are
# deployed to TARGET_DIR/modules/ by install_runtime_modules() — not sourced here.
source "$MODULES_DIR/utilities.sh"
source "$MODULES_DIR/java_management.sh"
source "$MODULES_DIR/launcher_setup.sh"
source "$MODULES_DIR/version_management.sh"
source "$MODULES_DIR/lwjgl_management.sh"
source "$MODULES_DIR/mod_management.sh"
source "$MODULES_DIR/instance_creation.sh"
source "$MODULES_DIR/steam_integration.sh"
source "$MODULES_DIR/desktop_launcher.sh"
source "$MODULES_DIR/main_workflow.sh"

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Script configuration paths
readonly TARGET_DIR="$HOME/.local/share/PolyMC"

# Runtime variables (set during execution)
JAVA_PATH=""
MC_VERSION=""
FABRIC_VERSION=""
LWJGL_VERSION=""

# Mod configuration arrays — populated by load_mods_config() below.
declare -a REQUIRED_SPLITSCREEN_MODS=()
declare -a REQUIRED_SPLITSCREEN_IDS=()
declare -a MODS=()
# Dependency map: mod name → comma-separated names of mods it requires.
# Used by resolve_conf_dependencies() in mod_management.sh.
declare -A MOD_DEPS_BY_NAME=()

# load_mods_config: Populate MODS, REQUIRED_SPLITSCREEN_MODS, and
# REQUIRED_SPLITSCREEN_IDS from mods.conf (next to this script).
# Falls back to built-in defaults if the file is missing.
load_mods_config() {
    local conf="${SCRIPT_DIR}/mods.conf"

    if [[ ! -f "$conf" ]]; then
        echo "[mods] mods.conf not found at ${conf} — using built-in defaults" >&2
        # NOTE: the "Splitscreen Support" mod (yJgqfSDR) is NO LONGER installed — window
        # tiling is done by KWin, not the mod (2026-06-23). Only Controlify is required.
        REQUIRED_SPLITSCREEN_MODS=("Controlify")
        REQUIRED_SPLITSCREEN_IDS=("DOUdJVEm")
        MODS=(
            "Controlify|modrinth|DOUdJVEm"
            "Sodium|modrinth|AANobbMI"
            "Sodium Options API|modrinth|Es5v4eyq"
            "Reese's Sodium Options|modrinth|Bh37bMuy"
            "Sodium Extra|modrinth|PtjYWJkn"
            "Sodium Extras|modrinth|vqqx0QiE"
            "Sodium Dynamic Lights|modrinth|PxQSWIcD"
            "Better Name Visibility|modrinth|pSfNeCCY"
            "Full Brightness Toggle|modrinth|aEK1KhsC"
            "In-Game Account Switcher|modrinth|cudtvDnd"
            "Just Zoom|modrinth|iAiqcykM"
            "Mod Menu|modrinth|mOgUt4GM"
            "Old Combat Mod|modrinth|dZ1APLkO"
        )
        MOD_DEPS_BY_NAME=(
            ["Sodium Options API"]="Sodium"
            ["Reese's Sodium Options"]="Sodium,Sodium Options API"
            ["Sodium Extra"]="Sodium"
            ["Sodium Extras"]="Sodium"
            ["Sodium Dynamic Lights"]="Sodium"
        )
        return 0
    fi

    echo "[mods] Loading mod list from ${conf}" >&2
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip inline comments, then leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        local type name platform id deps
        IFS='|' read -r type name platform id deps <<< "$line"
        # Trim whitespace from each field
        type="${type// /}"
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        platform="${platform// /}"; id="${id// /}"
        deps="${deps#"${deps%%[![:space:]]*}"}"; deps="${deps%"${deps##*[![:space:]]}"}"

        MODS+=("${name}|${platform}|${id}")

        if [[ "$type" == "required" ]]; then
            REQUIRED_SPLITSCREEN_MODS+=("$name")
            REQUIRED_SPLITSCREEN_IDS+=("$id")
        fi

        if [[ -n "$deps" ]]; then
            MOD_DEPS_BY_NAME["$name"]="$deps"
        fi
    done < "$conf"

    echo "[mods] Loaded ${#MODS[@]} mods (${#REQUIRED_SPLITSCREEN_MODS[@]} required, ${#MOD_DEPS_BY_NAME[@]} with declared deps)" >&2
}

load_mods_config

# Runtime mod tracking arrays (populated during execution)
declare -a SUPPORTED_MODS=()
declare -a MOD_DESCRIPTIONS=()
declare -a MOD_URLS=()
declare -a MOD_IDS=()
declare -a MOD_TYPES=()
declare -a MOD_DEPENDENCIES=()
declare -a FINAL_MOD_INDEXES=()
declare -a MISSING_MODS=()

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

# Execute main function if script is run directly
# This allows the script to be sourced for testing without auto-execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${TESTING_MODE:-}" ]]; then
    main "$@"
fi

# =============================================================================
# END OF MODULAR MINECRAFT SPLITSCREEN INSTALLER
# =============================================================================
