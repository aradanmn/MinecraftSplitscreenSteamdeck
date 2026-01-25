#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - MODULAR VERSION
# =============================================================================
# Version: 2.0.0 (commit: auto-populated at runtime)
# Last Modified: 2026-01-23
# Source: https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
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
# - Auto-generated launcher script with correct paths
# - Support for both AppImage and Flatpak launchers
#
# No additional setup, Java installation, token files, or module downloads required - just run this script.
# Modules are downloaded temporarily and automatically cleaned up when the script completes.
#
# Usage:
#   # Standard (uses default repository: aradanmn/MinecraftSplitscreenSteamdeck, branch: main)
#   curl -fsSL https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/install-minecraft-splitscreen.sh | bash
#
#   # From a fork or different branch (auto-detects from URL via environment variable)
#   URL="https://raw.githubusercontent.com/OWNER/REPO/BRANCH/install-minecraft-splitscreen.sh"
#   INSTALLER_SOURCE_URL="$URL" curl -fsSL "$URL" | bash
#
#   # From a fork or different branch (via argument)
#   curl -fsSL URL | bash -s -- --source-url URL
#
#   # Local execution (auto-detects from git remote and current branch)
#   ./install-minecraft-splitscreen.sh
#
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

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

# Handler for interrupt signals (Ctrl+C, TERM)
interrupt_handler() {
    echo ""
    echo "❌ Installation cancelled by user"
    cleanup
    # Exit with 128 + signal number (standard convention)
    # SIGINT=2, SIGTERM=15
    exit 130
}

# Set up traps:
# - EXIT: cleanup on normal exit or error
# - INT/TERM: cleanup AND exit immediately (for Ctrl+C)
trap cleanup EXIT
trap interrupt_handler INT TERM

# =============================================================================
# MODULE DOWNLOADING AND LOADING
# =============================================================================

# Get the directory where this script is located
# Handle both direct execution and curl | bash piping
# When piped, BASH_SOURCE is empty so we fall back to current directory
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" != "bash" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Running via curl | bash - use current directory
    readonly SCRIPT_DIR="$(pwd)"
fi

# Create a temporary directory for modules that will be cleaned up automatically
MODULES_DIR="$(mktemp -d -t minecraft-modules-XXXXXX)"

# =============================================================================
# REPOSITORY CONFIGURATION
# =============================================================================
# Default values - used when running locally or when URL parsing fails
DEFAULT_REPO_OWNER="aradanmn"
DEFAULT_REPO_NAME="MinecraftSplitscreenSteamdeck"
DEFAULT_REPO_BRANCH="main"

# Initialize with defaults
BOOTSTRAP_REPO_OWNER="$DEFAULT_REPO_OWNER"
BOOTSTRAP_REPO_NAME="$DEFAULT_REPO_NAME"
BOOTSTRAP_REPO_BRANCH="$DEFAULT_REPO_BRANCH"

# @function parse_github_raw_url
# @description Extracts owner, repo, and branch from a GitHub raw URL
# @param $1 - GitHub raw URL (e.g., https://raw.githubusercontent.com/owner/repo/branch/path)
# @return Sets BOOTSTRAP_REPO_OWNER, BOOTSTRAP_REPO_NAME, BOOTSTRAP_REPO_BRANCH
parse_github_raw_url() {
    local url="$1"

    # Pattern: https://raw.githubusercontent.com/OWNER/REPO/BRANCH/...
    if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/ ]]; then
        BOOTSTRAP_REPO_OWNER="${BASH_REMATCH[1]}"
        BOOTSTRAP_REPO_NAME="${BASH_REMATCH[2]}"
        BOOTSTRAP_REPO_BRANCH="${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# @function detect_source_url
# @description Attempts to detect the URL used to download this script
# @return Sets repository variables if URL can be determined
detect_source_url() {
    # Method 1: Check for --source-url argument
    # Usage: curl URL | bash -s -- --source-url URL
    local i=1
    for arg in "$@"; do
        if [[ "$arg" == "--source-url" ]]; then
            local next_idx=$((i + 1))
            local url="${!next_idx:-}"
            if [[ -n "$url" ]] && parse_github_raw_url "$url"; then
                echo "📍 Source URL provided via argument"
                return 0
            fi
        fi
        ((i++))
    done

    # Method 2: Check INSTALLER_SOURCE_URL environment variable
    # Usage: INSTALLER_SOURCE_URL=URL curl URL | bash
    if [[ -n "${INSTALLER_SOURCE_URL:-}" ]]; then
        if parse_github_raw_url "$INSTALLER_SOURCE_URL"; then
            echo "📍 Source URL provided via INSTALLER_SOURCE_URL environment variable"
            return 0
        fi
    fi

    # Method 3: If running from a git repo, detect from git remote
    if [[ -d "$SCRIPT_DIR/.git" ]] || git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
        local remote_url
        remote_url=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)

        if [[ -n "$remote_url" ]]; then
            # Parse git@github.com:owner/repo.git or https://github.com/owner/repo.git
            if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
                BOOTSTRAP_REPO_OWNER="${BASH_REMATCH[1]}"
                BOOTSTRAP_REPO_NAME="${BASH_REMATCH[2]}"
                # Get current branch
                BOOTSTRAP_REPO_BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "$DEFAULT_REPO_BRANCH")
                echo "📍 Detected repository from local git: $BOOTSTRAP_REPO_OWNER/$BOOTSTRAP_REPO_NAME ($BOOTSTRAP_REPO_BRANCH)"
                return 0
            fi
        fi
    fi

    # Fall back to defaults
    echo "📍 Using default repository: $DEFAULT_REPO_OWNER/$DEFAULT_REPO_NAME ($DEFAULT_REPO_BRANCH)"
    return 0
}

# Detect source URL and set repository variables
detect_source_url "$@"

# Build the modules URL from detected/default values
readonly BOOTSTRAP_REPO_MODULES_URL="https://raw.githubusercontent.com/${BOOTSTRAP_REPO_OWNER}/${BOOTSTRAP_REPO_NAME}/${BOOTSTRAP_REPO_BRANCH}/modules"

# List of required module files (order matters for dependencies)
# path_configuration.sh MUST be loaded right after utilities.sh as it's the single source of truth for paths
readonly MODULE_FILES=(
    "version_info.sh"
    "utilities.sh"
    "path_configuration.sh"
#    "launcher_detection.sh"
    "launcher_script_generator.sh"
    "java_management.sh"
    "launcher_setup.sh"
    "version_management.sh"
    "lwjgl_management.sh"
    "mod_management.sh"
    "instance_creation.sh"
    "pollymc_setup.sh"
    "steam_integration.sh"
    "desktop_launcher.sh"
    "main_workflow.sh"
)

# Function to download modules if they don't exist
download_modules() {
    echo "🔄 Downloading required modules to temporary directory..."
    echo "📁 Temporary modules directory: $MODULES_DIR"
    echo "🌐 Repository URL: $BOOTSTRAP_REPO_MODULES_URL"

    # Temporarily disable strict error handling for downloads
    set +e

    # The temporary directory is already created by mktemp
    local downloaded_count=0
    local failed_count=0

    # Download each required module
    for module in "${MODULE_FILES[@]}"; do
        local module_path="$MODULES_DIR/$module"
        local module_url="$BOOTSTRAP_REPO_MODULES_URL/$module"

        echo "⬇️  Downloading module: $module"
        echo "    URL: $module_url"

        # Download the module file
        if command -v curl >/dev/null 2>&1; then
            curl_output=$(curl -fsSL "$module_url" -o "$module_path" 2>&1)
            curl_exit_code=$?
            if [[ $curl_exit_code -eq 0 ]]; then
                chmod +x "$module_path"
                ((downloaded_count++))
                echo "✅ Downloaded: $module"
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
                echo "✅ Downloaded: $module"
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
        echo "🌐 Or check if the repository exists at: https://github.com/${BOOTSTRAP_REPO_OWNER}/${BOOTSTRAP_REPO_NAME}"
        exit 1
    fi

    echo "✅ Downloaded $downloaded_count module(s) to temporary directory"
    echo "ℹ️  Modules will be automatically cleaned up when script completes"
}

# Download modules if needed
# First check if modules exist locally, if not try to download them
if [[ -d "$SCRIPT_DIR/modules" ]]; then
    echo "📁 Found local modules directory, copying to temporary location..."
    cp -r "$SCRIPT_DIR/modules/"* "$MODULES_DIR/"
    chmod +x "$MODULES_DIR"/*.sh 2>/dev/null || true
    echo "✅ Copied local modules to temporary directory"
else
    download_modules
fi

# Verify all modules are now present
for module in "${MODULE_FILES[@]}"; do
    if [[ ! -f "$MODULES_DIR/$module" ]]; then
        echo "❌ Error: Required module missing: $module"
        echo "Please check your internet connection or download manually from:"
        echo "$BOOTSTRAP_REPO_MODULES_URL/$module"
        exit 1
    fi
done

# Source all module files to load their functions
# Load modules in dependency order:
# 1. version_info first for constants
# 2. utilities for logging functions
# 3. path_configuration for centralized path management (SINGLE SOURCE OF TRUTH)
# 4. All other modules
source "$MODULES_DIR/version_info.sh"
source "$MODULES_DIR/utilities.sh"
#source "$MODULES_DIR/launcher_detection.sh"
source "$MODULES_DIR/path_configuration.sh"
source "$MODULES_DIR/launcher_script_generator.sh"
source "$MODULES_DIR/java_management.sh"
source "$MODULES_DIR/launcher_setup.sh"
source "$MODULES_DIR/version_management.sh"
source "$MODULES_DIR/lwjgl_management.sh"
source "$MODULES_DIR/mod_management.sh"
source "$MODULES_DIR/instance_creation.sh"
source "$MODULES_DIR/pollymc_setup.sh"
source "$MODULES_DIR/steam_integration.sh"
source "$MODULES_DIR/desktop_launcher.sh"
source "$MODULES_DIR/main_workflow.sh"

# Now that version_info.sh is loaded, we can use REPO_MODULES_URL
# This is used by download_modules when running from curl | bash

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# NOTE: Launcher paths are now managed by path_configuration.sh
# Use ACTIVE_DATA_DIR, ACTIVE_INSTANCES_DIR, CREATION_DATA_DIR, etc.
# DO NOT use hardcoded PRISMLAUNCHER_DIR or POLLYMC_DIR

# Runtime variables (set during execution)
JAVA_PATH=""
MC_VERSION=""
FABRIC_VERSION=""
LWJGL_VERSION=""

# Mod configuration arrays
declare -a REQUIRED_SPLITSCREEN_MODS=("Controllable (Fabric)" "Splitscreen Support")
declare -a REQUIRED_SPLITSCREEN_IDS=("317269" "yJgqfSDR")

# Master list of all available mods with their metadata
# Format: "Mod Name|platform|mod_id"
declare -a MODS=(
    "Better Name Visibility|modrinth|pSfNeCCY"
    "Controllable (Fabric)|curseforge|317269"
    "Full Brightness Toggle|modrinth|aEK1KhsC"
    "In-Game Account Switcher|modrinth|cudtvDnd"
    "Just Zoom|modrinth|iAiqcykM"
    "Legacy4J|modrinth|gHvKJofA"
    "Mod Menu|modrinth|mOgUt4GM"
    "Old Combat Mod|modrinth|dZ1APLkO"
    "Reese's Sodium Options|modrinth|Bh37bMuy"
    "Sodium|modrinth|AANobbMI"
    "Sodium Dynamic Lights|modrinth|PxQSWIcD"
    "Sodium Extra|modrinth|PtjYWJkn"
    "Sodium Extras|modrinth|vqqx0QiE"
    "Sodium Options API|modrinth|Es5v4eyq"
    "Splitscreen Support|modrinth|yJgqfSDR"
)

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

# Execute main function
# Works for both direct execution (./script.sh) and piped execution (curl | bash)
main "$@"

# =============================================================================
# END OF MODULAR MINECRAFT SPLITSCREEN INSTALLER
# =============================================================================
