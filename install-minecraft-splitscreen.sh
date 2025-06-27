#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - MODULAR VERSION
# =============================================================================
# 
# This is the new, clean modular entry point for the Minecraft Splitscreen installer.
# All functionality has been moved to organized modules for better maintainability.
#
# Features:
# - Automatic Java detection and installation
# - Complete Fabric dependency chain implementation
# - API filtering for Fabric-compatible mods (Modrinth + CurseForge)
# - Enhanced error handling with multiple fallback mechanisms
# - User-friendly mod selection interface
# - Steam Deck optimized installation
# - Comprehensive Steam and desktop integration
#
# No additional setup, Java installation, or token files are required - just run this script.
#
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# MODULE LOADING
# =============================================================================

# Get the directory where this script is located
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="$SCRIPT_DIR/modules"

# Verify modules directory exists
if [[ ! -d "$MODULES_DIR" ]]; then
    echo "❌ Error: modules directory not found at $MODULES_DIR"
    echo "Please ensure all module files are present in the modules/ directory"
    exit 1
fi

# Source all module files to load their functions
# Load modules in dependency order
source "$MODULES_DIR/utilities.sh"
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

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Script configuration paths
readonly TARGET_DIR="$HOME/.local/share/PrismLauncher"
readonly POLLYMC_DIR="$HOME/.local/share/PollyMC"

# Runtime variables (set during execution)
JAVA_PATH=""
MC_VERSION=""
FABRIC_VERSION=""
LWJGL_VERSION=""
USE_POLLYMC=false

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

# Execute main function if script is run directly
# This allows the script to be sourced for testing without auto-execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${TESTING_MODE:-}" ]]; then
    main "$@"
fi

# =============================================================================
# END OF MODULAR MINECRAFT SPLITSCREEN INSTALLER
# =============================================================================
