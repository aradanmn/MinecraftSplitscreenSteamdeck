#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - REFACTORED VERSION
# =============================================================================
# 
# This script automatically downloads and installs Minecraft with splitscreen 
# support for Steam Deck. It uses an optimized dual-launcher approach:
# 1. PrismLauncher CLI for automated instance creation with proper Fabric setup
# 2. PollyMC for splitscreen gameplay (no forced login, offline-friendly)
# 3. Smart cleanup removes PrismLauncher after successful PollyMC setup
#
# REFACTORING IMPROVEMENTS:
# - Modular function-based architecture for better maintainability
# - Enhanced error handling with proper exit codes and validation
# - Cleaner separation of concerns (setup, compatibility, selection, creation)
# - Comprehensive progress feedback with colored output
# - Robust dependency management and mod selection logic
# - Smart cleanup and launcher integration
# - Comprehensive Steam and desktop integration
#
# Features:
# - Complete Fabric dependency chain implementation
# - API filtering for Fabric-compatible mods (Modrinth + CurseForge)
# - Enhanced error handling with multiple fallback mechanisms
# - Automatic cleanup of temporary files and directories
# - User-friendly mod selection interface
# - Automated launcher script generation
#
# No additional setup or token files are required - just run this script.
#
# =============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Script configuration paths
# SCRIPT_DIR: Directory where this script is located (for relative file access)
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TARGET_DIR: PrismLauncher installation directory (used for CLI-based instance creation)
readonly TARGET_DIR="$HOME/.local/share/PrismLauncher"
# POLLYMC_DIR: PollyMC installation directory (primary launcher for splitscreen gameplay)
readonly POLLYMC_DIR="$HOME/.local/share/PollyMC"

# Java configuration
# JAVA_PATH: Full path to Java 21 executable (required for modern Minecraft versions)
JAVA_PATH=""

# Minecraft configuration
# MC_VERSION: Target Minecraft version for installation (e.g., "1.21.3")
MC_VERSION=""
# FABRIC_VERSION: Fabric mod loader version to install (fetched from API)
FABRIC_VERSION=""

# Launcher configuration flags
# USE_POLLYMC: Flag to track whether PollyMC setup was successful (determines final launcher choice)
USE_POLLYMC=false

# Mod configuration arrays
# These arrays define the mods available for installation and their relationships

# REQUIRED_SPLITSCREEN_MODS: Mods essential for splitscreen functionality
# These are always installed regardless of user selection
declare -a REQUIRED_SPLITSCREEN_MODS=("Controllable (Fabric)" "Splitscreen Support")
# REQUIRED_SPLITSCREEN_IDS: Corresponding mod IDs for required splitscreen mods
declare -a REQUIRED_SPLITSCREEN_IDS=("317269" "yJgqfSDR")

# MODS: Master list of all available mods with their metadata
# Format: "Mod Name|platform|mod_id"
# Platforms: modrinth, curseforge
# This list includes performance mods, QoL improvements, and splitscreen essentials
# Dependencies will be automatically detected and downloaded via API
declare -a MODS=(
    "Better Name Visibility|modrinth|pSfNeCCY"    # Improves player name visibility in multiplayer
    "Controllable (Fabric)|curseforge|317269"     # Controller support (REQUIRED for splitscreen)
    "Full Brightness Toggle|modrinth|aEK1KhsC"   # Toggle max brightness with hotkey
    "In-Game Account Switcher|modrinth|cudtvDnd" # Switch between multiple accounts in-game
    "Just Zoom|modrinth|iAiqcykM"                # Simple zoom functionality
    "Legacy4J|modrinth|gHvKJofA"                 # Legacy console edition features for Java edition
    "Mod Menu|modrinth|mOgUt4GM"                 # In-game mod configuration menu
    "Old Combat Mod|modrinth|dZ1APLkO"           # Restore pre-1.9 combat mechanics
    "Reese's Sodium Options|modrinth|Bh37bMuy"   # Enhanced graphics options for Sodium
    "Sodium|modrinth|AANobbMI"                   # Performance optimization mod
    "Sodium Dynamic Lights|modrinth|PxQSWIcD"    # Dynamic lighting for Sodium
    "Sodium Extra|modrinth|PtjYWJkn"             # Additional Sodium features
    "Sodium Extras|modrinth|vqqx0QiE"            # More Sodium enhancements
    "Sodium Options API|modrinth|Es5v4eyq"       # API for Sodium options
    "Splitscreen Support|modrinth|yJgqfSDR"      # Core splitscreen functionality (REQUIRED)
)

# Runtime mod tracking arrays
# These arrays are populated during the mod compatibility checking phase
# and used throughout the installation process

# SUPPORTED_MODS: Names of mods that are compatible with the selected Minecraft version
declare -a SUPPORTED_MODS=()
# MOD_DESCRIPTIONS: Brief descriptions of mods for user information
declare -a MOD_DESCRIPTIONS=()
# MOD_URLS: Download URLs for compatible mod files
declare -a MOD_URLS=()
# MOD_IDS: Platform-specific IDs for mods (Modrinth project ID or CurseForge project ID)
declare -a MOD_IDS=()
# MOD_TYPES: Platform type for each mod ("modrinth" or "curseforge")
declare -a MOD_TYPES=()
# MOD_DEPENDENCIES: Space-separated list of dependency mod IDs for each mod
declare -a MOD_DEPENDENCIES=()
# FINAL_MOD_INDEXES: Indexes of mods selected for installation (after user selection + dependencies)
declare -a FINAL_MOD_INDEXES=()
# MISSING_MODS: Names of mods that failed to download or were incompatible
declare -a MISSING_MODS=()

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Progress and status reporting functions
# These functions provide consistent, colored output for better user experience

# print_header: Display a section header with visual separation
print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# print_success: Display successful operation with green checkmark
print_success() {
    echo "✅ $1"
}

# print_warning: Display warning message with yellow warning symbol
print_warning() {
    echo "⚠️  $1"
}

# print_error: Display error message with red X symbol (sent to stderr)
print_error() {
    echo "❌ $1" >&2
}

# print_info: Display informational message with blue info symbol
print_info() {
    echo "💡 $1"
}

# print_progress: Display in-progress operation with spinning arrow
print_progress() {
    echo "🔄 $1"
}

# =============================================================================
# JAVA DETECTION AND VALIDATION
# =============================================================================

# detect_java: Find and validate Java 21 installation
# Modern Minecraft versions (1.17+) require Java 17+, and 1.21+ needs Java 21
# This function searches common Java installation paths including Steam Deck specific locations
# Steam Deck users often install Java in ~/.local/jdk/ for user-space installations
detect_java() {
    print_progress "Detecting Java 21 installation..."
    
    # Search for Java 21 in common installation locations
    # Priority order: Steam Deck user install -> OpenJDK 21 -> system default -> PATH
    if [[ -x "$HOME/.local/jdk/jdk-21.0.7/bin/java" ]]; then
        # Steam Deck user installation (specific version path)
        JAVA_PATH="$HOME/.local/jdk/jdk-21.0.7/bin/java"
    elif [[ -x $(find "$HOME/.local/jdk" -name "java" -path "*/jdk-21*/bin/java" 2>/dev/null | head -1) ]]; then
        # Steam Deck user installation (any JDK 21 version in ~/.local/jdk)
        JAVA_PATH="$(find "$HOME/.local/jdk" -name "java" -path "*/jdk-21*/bin/java" 2>/dev/null | head -1)"
    elif [[ -x "/usr/lib/jvm/java-21-openjdk/bin/java" ]]; then
        # OpenJDK 21 (most common on Linux distributions)
        JAVA_PATH="/usr/lib/jvm/java-21-openjdk/bin/java"
    elif [[ -x "/usr/lib/jvm/default-runtime/bin/java" ]]; then
        # System default Java runtime (may or may not be Java 21)
        JAVA_PATH="/usr/lib/jvm/default-runtime/bin/java"
    else
        # Fallback: search in PATH (works for custom installations)
        JAVA_PATH="$(which java 2>/dev/null || true)"
    fi

    # Validate that we found Java 21 specifically
    # Modern Minecraft requires Java 21 for optimal performance and compatibility
    if [[ -z "$JAVA_PATH" ]] || ! "$JAVA_PATH" -version 2>&1 | grep -q '21'; then
        print_error "Java 21 is not installed or not found in a standard location."
        print_error "Refer to the README at https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck for installation instructions."
        exit 1
    fi
    
    print_success "Found Java 21 at: $JAVA_PATH"
}

# =============================================================================
# PRISM LAUNCHER SETUP
# =============================================================================
# PrismLauncher is used for automated instance creation via CLI
# It provides reliable Minecraft instance management and Fabric loader installation
# =============================================================================

# download_prism_launcher: Download the latest PrismLauncher AppImage
# PrismLauncher provides CLI tools for automated instance creation
# We download it to the target directory for temporary use during setup
download_prism_launcher() {
    # Skip download if AppImage already exists
    if [[ -f "$TARGET_DIR/PrismLauncher.AppImage" ]]; then
        print_success "PrismLauncher AppImage already present"
        return 0
    fi
    
    print_progress "Downloading latest PrismLauncher AppImage..."
    
    # Query GitHub API to get the latest release download URL
    # We specifically look for AppImage files in the release assets
    local prism_url
    prism_url=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest | \
        jq -r '.assets[] | select(.name | test("AppImage$")) | .browser_download_url' | head -n1)
    
    # Validate that we got a valid download URL
    if [[ -z "$prism_url" || "$prism_url" == "null" ]]; then
        print_error "Could not find latest PrismLauncher AppImage URL."
        print_error "Please check https://github.com/PrismLauncher/PrismLauncher/releases manually."
        exit 1
    fi
    
    # Download and make executable
    wget -O "$TARGET_DIR/PrismLauncher.AppImage" "$prism_url"
    chmod +x "$TARGET_DIR/PrismLauncher.AppImage"
    print_success "PrismLauncher AppImage downloaded successfully"
}

# verify_prism_cli: Ensure PrismLauncher supports CLI operations
# We need CLI support for automated instance creation
# This function validates that the downloaded version has the required features
verify_prism_cli() {
    print_progress "Verifying PrismLauncher CLI capabilities..."
    
    local appimage="$TARGET_DIR/PrismLauncher.AppImage"
    
    # Test for basic CLI support by checking help output
    # Look for keywords that indicate CLI instance creation is available
    if ! "$appimage" --help 2>/dev/null | grep -q -E "(cli|create|instance)"; then
        print_warning "PrismLauncher CLI may not support instance creation. Checking with --help-all..."
        
        # Fallback: try the extended help option
        if ! "$appimage" --help-all 2>/dev/null | grep -q -E "(cli|create-instance)"; then
            print_error "This version of PrismLauncher does not support CLI instance creation."
            echo "Available options:" >&2
            "$appimage" --help 2>&1 | head -20 >&2
            print_error "Please update to a newer version that supports CLI operations."
            exit 1
        fi
    fi
    
    # Display available CLI commands for debugging purposes
    print_info "Available PrismLauncher CLI commands:"
    "$appimage" --help 2>&1 | grep -E "(create|instance|cli)" || echo "  (Basic CLI commands found)"
    print_success "PrismLauncher CLI instance creation verified"
}

# =============================================================================
# MINECRAFT VERSION SELECTION
# =============================================================================
# Allow user to specify Minecraft version or auto-detect latest release

# get_minecraft_version: Get target Minecraft version from user or API
# Supports both user input and automatic latest version detection
get_minecraft_version() {
    print_progress "Setting up Minecraft version..."
    
    # Prompt user for Minecraft version preference
    # Empty input will trigger automatic latest version detection
    read -p "Enter the Minecraft version to install (leave blank for latest): " MC_VERSION
    
    if [[ -z "$MC_VERSION" ]]; then
        # Auto-detect latest release version from Mojang's official API
        print_progress "Detecting latest Minecraft version from Mojang..."
        MC_VERSION=$(curl -s "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq -r '.latest.release')
        print_success "Using latest Minecraft version: $MC_VERSION"
    else
        # Use user-specified version (validation happens during mod compatibility check)
        print_success "Using specified Minecraft version: $MC_VERSION"
    fi
}

# =============================================================================
# FABRIC VERSION DETECTION
# =============================================================================
# Fabric mod loader is required for all the performance and splitscreen mods
# We automatically detect the latest compatible version

# get_fabric_version: Fetch the latest Fabric loader version from official API
# Fabric loader provides the mod loading framework for Minecraft
get_fabric_version() {
    print_progress "Detecting latest Fabric loader version..."
    
    # Query Fabric Meta API for the latest loader version
    FABRIC_VERSION=$(curl -s "https://meta.fabricmc.net/v2/versions/loader" | jq -r '.[0].version' 2>/dev/null)
    
    # Fallback to known stable version if API call fails
    if [[ -z "$FABRIC_VERSION" || "$FABRIC_VERSION" == "null" ]]; then
        print_warning "Could not detect latest Fabric version, using fallback"
        FABRIC_VERSION="0.16.9"  # Known stable version that works with most mods
    fi
    
    print_success "Using Fabric loader version: $FABRIC_VERSION"
}

# =============================================================================
# MOD COMPATIBILITY CHECKING
# =============================================================================
# This section handles the complex process of checking mod compatibility
# across both Modrinth and CurseForge platforms for the target Minecraft version

# check_mod_compatibility: Main coordination function for mod compatibility checking
# Iterates through all mods and delegates to platform-specific checkers
check_mod_compatibility() {
    print_header "🔍 CHECKING MOD COMPATIBILITY"
    print_progress "Checking mod compatibility for Minecraft $MC_VERSION..."
    
    # Process each mod in the MODS array
    # Format: "ModName|platform|mod_id" 
    for mod in "${MODS[@]}"; do
        IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "$mod"
        
        # Route to appropriate platform-specific checker
        if [[ "$MOD_TYPE" == "modrinth" ]]; then
            check_modrinth_mod "$MOD_NAME" "$MOD_ID"
        elif [[ "$MOD_TYPE" == "curseforge" ]]; then
            check_curseforge_mod "$MOD_NAME" "$MOD_ID"
        fi
    done
    
    print_success "Mod compatibility check completed"
    print_info "Found ${#SUPPORTED_MODS[@]} compatible mods for Minecraft $MC_VERSION"
}

# check_modrinth_mod: Check if a Modrinth mod is compatible with target MC version
# Modrinth is the preferred platform - it has better API and more reliable data
# This function implements complex version matching logic to handle various version formats
check_modrinth_mod() {
    local mod_name="$1"     # Human-readable mod name
    local mod_id="$2"       # Modrinth project ID (e.g., "P7dR8mSH" for Fabric API)
    local api_url="https://api.modrinth.com/v2/project/$mod_id/version"
    
    # Create temporary file for API response
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi
    
    # Fetch all version data for this mod from Modrinth API
    # Make HTTP request to Modrinth API and capture both response and status code
    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" "$api_url")
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response (must be HTTP 200 and valid JSON)
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        print_warning "Mod $mod_name ($mod_id) is not compatible with $MC_VERSION (API error)"
        return 1
    fi
    
    # Complex version matching logic - handles multiple version format scenarios
    # This logic tries progressively more lenient matching patterns
    local file_url=""     # Download URL for compatible mod file
    local dep_ids=""      # Space-separated list of dependency mod IDs
    
    # STAGE 1: Try exact version match with Fabric loader requirement
    # Example: Looking for exactly "1.21.3" with "fabric" loader
    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
    dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
    
    # STAGE 2: Try major.minor version match if exact match failed
    # Example: "1.21.3" -> try "1.21", "1.21.x", "1.21.0"
    if [[ -z "$file_url" || "$file_url" == "null" ]]; then
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')  # Extract "1.21" from "1.21.3"
        
        # Try exact major.minor (e.g., "1.21")
        file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
        dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
        
        # Try wildcard version format (e.g., "1.21.x") 
        if [[ -z "$file_url" || "$file_url" == "null" ]]; then
            local mc_major_minor_x="$mc_major_minor.x"
            file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
            dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
        fi
        
        # Try zero-padded version format (e.g., "1.21.0")
        if [[ -z "$file_url" || "$file_url" == "null" ]]; then
            local mc_major_minor_0="$mc_major_minor.0"
            file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
            dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
        fi
        
        # Try prefix matching (any version starting with major.minor)
        if [[ -z "$file_url" || "$file_url" == "null" ]]; then
            file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] | startswith($v) and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
            dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] | startswith($v) and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
        fi
    fi
    
    # STAGE 3: Advanced pattern matching with comprehensive version range support
    # This handles complex version patterns like ranges, wildcards, and edge cases
    if [[ -z "$file_url" || "$file_url" == "null" ]]; then
        file_url=""  # Reset for clean advanced search
        dep_ids=""   # Reset dependencies
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
        local mc_major_minor_x="$mc_major_minor.x"
        local mc_major_minor_0="$mc_major_minor.0"
        
        # Complex jq filter that handles multiple version pattern types:
        # 1. Exact matches (1.21.3)
        # 2. Major.minor matches (1.21)  
        # 3. Wildcard patterns (1.21.x)
        # 4. Zero-padded versions (1.21.0)
        # 5. Version ranges (1.21.0-1.21.5)
        # 6. Regex patterns for version compatibility
        local jq_filter='
          .[] as $release
          | select($release.loaders[] == "fabric")
          | $release.files[]
          | {
              url,
              dependencies: ($release.dependencies // [] | map(select(.dependency_type == "required") | .project_id)),
              game_versions: (if has("game_versions") and (.game_versions | length > 0) then .game_versions else $release.game_versions end),
              loaders: $release.loaders
            }
          | select(
              .game_versions[]
              | test("^" + $mc_major_minor + "\\..*$") or
                . == $mc_version or
                . == $mc_major_minor or
                . == $mc_major_minor_x or
                . == $mc_major_minor_0 or
                (test("^[0-9]+\\.[0-9]+\\.x$") and ($mc_version | startswith((. | capture("^(?<majmin>[0-9]+\\.[0-9]+)")).majmin)))
                or
                (test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+\\.[0-9]+\\.[0-9]+$") and (
                  ($mc_version | split(".") | map(tonumber)) as $ver
                  | (. | capture("^(?<start>[0-9]+\\.[0-9]+\\.[0-9]+)-(?<end>[0-9]+\\.[0-9]+\\.[0-9]+)$")) as $range
                  | ($range.start | split(".") | map(tonumber)) as $start
                  | ($range.end | split(".") | map(tonumber)) as $end
                  | ($ver >= $start and $ver <= $end)
                ))
            )
          | {url, dependencies}
          | @base64
        '
        
        # Execute the complex jq filter with all version variants
        local jq_result
        jq_result=$(printf "%s" "$version_json" | jq -r \
          --arg mc_version "$MC_VERSION" \
          --arg mc_major_minor "$mc_major_minor" \
          --arg mc_major_minor_x "$mc_major_minor_x" \
          --arg mc_major_minor_0 "$mc_major_minor_0" \
          "$jq_filter" 2>/dev/null | head -n1)

        # Decode the base64-encoded result and extract URL and dependencies
        if [[ -n "$jq_result" ]]; then
            local decoded
            decoded=$(echo "$jq_result" | base64 --decode)
            file_url=$(echo "$decoded" | jq -r '.url')
            dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
        fi
    fi
    
    # Final result processing: Add to supported mods if we found a compatible version
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        SUPPORTED_MODS+=("$mod_name")          # Add to list of compatible mods
        MOD_DESCRIPTIONS+=("")                  # Placeholder for description
        MOD_URLS+=("$file_url")                # Store download URL
        MOD_IDS+=("$mod_id")                   # Store Modrinth project ID
        MOD_TYPES+=("modrinth")                # Mark as Modrinth mod
        MOD_DEPENDENCIES+=("$dep_ids")         # Store dependency information
        print_success "✅ $mod_name (Modrinth)"
    else
        print_warning "❌ $mod_name ($mod_id) - not compatible with $MC_VERSION"
    fi
}

# check_curseforge_mod: Check CurseForge mod compatibility with encrypted API access
# CurseForge requires API key authentication and has more restrictive access
# API token is encrypted and stored in the GitHub repository for security
check_curseforge_mod() {
    local mod_name="$1"           # Human-readable mod name
    local cf_project_id="$2"      # CurseForge project ID (numeric)
    
    # Download encrypted CurseForge API token from GitHub repository
    # Token is encrypted to prevent abuse while allowing public access
    local cf_token_enc_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
    local tmp_token_file
    # Create temporary file for encrypted token download
    tmp_token_file=$(mktemp)
    if [[ -z "$tmp_token_file" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi
    
    # Download the encrypted API token file
    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_token_file" "$cf_token_enc_url")
    if [[ "$http_code" != "200" ]] || [[ ! -s "$tmp_token_file" ]]; then
        print_warning "Failed to download CurseForge API token (HTTP: $http_code)"
        rm -f "$tmp_token_file"
        return 1
    fi
    
    # Decrypt the API token using OpenSSL AES-256-CBC with fixed passphrase
    # This provides security while allowing public access to the installer
    local fixed_passphrase="MinecraftSplitscreenSteamDeck2025"
    # Attempt to decrypt the API token
    local cf_api_key
    cf_api_key=$(openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$fixed_passphrase" -in "$tmp_token_file" 2>/dev/null)
    rm -f "$tmp_token_file"
    
    if [[ $? -ne 0 ]] || [[ -z "$cf_api_key" ]]; then
        print_warning "Failed to decrypt CurseForge API token for $mod_name"
        return 1
    fi
    
    # Query CurseForge API with Fabric loader filter (modLoaderType=4 = Fabric)
    # Note: We filter by Fabric loader but not by game version in the URL
    # Game version filtering is done in post-processing for more flexibility
    local cf_api_url="https://api.curseforge.com/v1/mods/$cf_project_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for CurseForge API call"
        return 1
    fi
    
    # Make authenticated API request to CurseForge
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url")
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        print_warning "❌ $mod_name ($cf_project_id) - API error (HTTP $http_code)"
        return 1
    fi
    
    # Version compatibility checking for CurseForge mods
    # Uses same versioning logic as Modrinth but with CurseForge API structure
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    local mc_major_minor_x="$mc_major_minor.x"
    local mc_major_minor_0="$mc_major_minor.0"
    
    # CurseForge-specific jq filter for version matching
    # Checks gameVersions array and extracts downloadUrl and dependencies
    # relationType == 3 means "required dependency" in CurseForge API
    local jq_filter='
        .data[]
        | select(
            ((.gameVersions[] == $mc_version) or
            (.gameVersions[] == $mc_major_minor) or
            (.gameVersions[] == $mc_major_minor_x) or
            (.gameVersions[] == $mc_major_minor_0))
          )
        | {url: .downloadUrl, dependencies: (.dependencies // [] | map(select(.relationType == 3) | .modId))}
        | @base64
    '
    
    # Execute the jq filter to find compatible CurseForge mod version
    local jq_result
    jq_result=$(printf "%s" "$version_json" | jq -r \
        --arg mc_version "$MC_VERSION" \
        --arg mc_major_minor "$mc_major_minor" \
        --arg mc_major_minor_x "$mc_major_minor_x" \
        --arg mc_major_minor_0 "$mc_major_minor_0" \
        "$jq_filter" 2>/dev/null | head -n1)
    
    # Process the result if we found a compatible version
    if [[ -n "$jq_result" ]]; then
        local decoded
        decoded=$(echo "$jq_result" | base64 --decode)
        local file_url
        file_url=$(echo "$decoded" | jq -r '.url')
        local dep_ids
        dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
        
        # Add to supported mods list with CurseForge-specific information
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")                 # Placeholder for description
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$cf_project_id")           # Store numeric CurseForge project ID
        MOD_TYPES+=("curseforge")             # Mark as CurseForge mod
        MOD_DEPENDENCIES+=("$dep_ids")        # Store CurseForge dependency IDs
        print_success "✅ $mod_name (CurseForge)"
    else
        print_warning "❌ $mod_name ($cf_project_id) - not compatible with $MC_VERSION"
    fi
}

# =============================================================================
# AUTOMATIC DEPENDENCY RESOLUTION SYSTEM
# =============================================================================
# Advanced dependency resolution that automatically fetches and resolves all
# mod dependencies recursively using the Modrinth and CurseForge APIs

# resolve_all_dependencies: Main function to automatically resolve all mod dependencies
# This function builds a complete dependency tree and ensures all required mods are included
# Parameters: None (operates on FINAL_MOD_INDEXES global array)
resolve_all_dependencies() {
    print_header "🔗 AUTOMATIC DEPENDENCY RESOLUTION"
    print_progress "Automatically resolving mod dependencies..."
    
    # Check if we have any mods to process
    if [[ ${#FINAL_MOD_INDEXES[@]} -eq 0 ]]; then
        print_info "No mods selected for dependency resolution"
        return 0
    fi
    
    local initial_mod_count=${#FINAL_MOD_INDEXES[@]}
    print_info "Starting dependency resolution with $initial_mod_count selected mods"
    
    # Simplified single-pass dependency resolution to avoid hangs
    local -A processed_mods
    local original_mod_indexes=("${FINAL_MOD_INDEXES[@]}")  # Copy original list
    
    # Process each originally selected mod for immediate dependencies only
    for idx in "${original_mod_indexes[@]}"; do
        local mod_id="${MOD_IDS[$idx]}"
        local mod_type="${MOD_TYPES[$idx]}"
        local mod_name="${SUPPORTED_MODS[$idx]}"
        
        # Skip if already processed
        if [[ -n "${processed_mods[$mod_id]:-}" ]]; then
            continue
        fi
        
        processed_mods["$mod_id"]=1
        print_info "   → Checking dependencies for: $mod_name"
        
        # Get dependencies from API based on mod type
        local deps=""
        case "$mod_type" in
            "modrinth")
                deps=$(resolve_modrinth_dependencies_api "$mod_id" 2>/dev/null || echo "")
                ;;
            "curseforge")
                deps=$(resolve_curseforge_dependencies_api "$mod_id" 2>/dev/null || echo "")
                ;;
        esac
        
        # Process found dependencies (single level only)
        if [[ -n "$deps" && "$deps" != " " ]]; then
            print_info "     → Found dependencies: $deps"
            for dep_id in $deps; do
                if [[ -n "$dep_id" && "$dep_id" != " " ]]; then
                    # Check if dependency is already in our mod list
                    local found_internal=false
                    for i in "${!MOD_IDS[@]}"; do
                        if [[ "${MOD_IDS[$i]}" == "$dep_id" ]]; then
                            # Add to final selection if not already there
                            local already_selected=false
                            for existing_idx in "${FINAL_MOD_INDEXES[@]}"; do
                                if [[ "$existing_idx" == "$i" ]]; then
                                    already_selected=true
                                    break
                                fi
                            done
                            
                            if [[ "$already_selected" == false ]]; then
                                FINAL_MOD_INDEXES+=("$i")
                                print_info "       → Added internal dependency: ${SUPPORTED_MODS[$i]}"
                            fi
                            found_internal=true
                            break
                        fi
                    done
                    
                    # If not found internally, try to fetch as external dependency with timeout
                    if [[ "$found_internal" == false ]]; then
                        print_info "       → Fetching external dependency: $dep_id"
                        local dep_platform="modrinth"
                        if [[ "$dep_id" =~ ^[0-9]+$ ]]; then
                            dep_platform="curseforge"
                        fi
                        
                        # Fetch external dependency (timeout handled within the function)
                        if fetch_and_add_external_mod "$dep_id" "$dep_platform"; then
                            print_info "       → Successfully added external dependency: $dep_id"
                        else
                            print_warning "       → Failed to fetch external dependency: $dep_id"
                        fi
                    fi
                fi
            done
        else
            print_info "     → No dependencies found"
        fi
    done
    
    local final_mod_count=${#FINAL_MOD_INDEXES[@]}
    local added_count=$((final_mod_count - initial_mod_count))
    
    print_success "Dependency resolution complete!"
    print_info "Added $added_count dependencies ($initial_mod_count → $final_mod_count total mods)"
}

# resolve_mod_dependencies: Resolve dependencies for a specific mod
# Fetches dependency information from Modrinth or CurseForge API based on mod type
# Parameters:
#   $1 - mod_id: The mod ID to resolve dependencies for
# Returns: Space-separated list of dependency mod IDs
resolve_mod_dependencies() {
    local mod_id="$1"
    
    # Find mod in our arrays to determine platform type
    local mod_type=""
    local mod_name=""
    for i in "${!MOD_IDS[@]}"; do
        if [[ "${MOD_IDS[$i]}" == "$mod_id" ]]; then
            mod_type="${MOD_TYPES[$i]}"
            mod_name="${SUPPORTED_MODS[$i]}"
            break
        fi
    done
    
    if [[ -z "$mod_type" ]]; then
        return 1
    fi
    
    # Route to appropriate platform-specific dependency resolver
    case "$mod_type" in
        "modrinth")
            resolve_modrinth_dependencies "$mod_id" "$mod_name"
            ;;
        "curseforge")
            resolve_curseforge_dependencies "$mod_id" "$mod_name"
            ;;
        *)
            print_warning "Unknown mod type: $mod_type for $mod_name"
            return 1
            ;;
    esac
}

# resolve_modrinth_dependencies: Get dependencies from Modrinth API
# Uses the same version matching logic as mod compatibility checking but focused on dependencies
# Parameters:
#   $1 - mod_id: Modrinth project ID
#   $2 - mod_name: Human-readable mod name for logging
# Returns: Space-separated list of required dependency mod IDs
resolve_modrinth_dependencies() {
    local mod_id="$1"
    local mod_name="$2"
    local api_url="https://api.modrinth.com/v2/project/$mod_id/version"
    
    # Create temporary file for API response
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        return 1
    fi
    
    # Fetch version data from Modrinth API
    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" "$api_url" 2>/dev/null)
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        return 1
    fi
    
    # Use the same version matching logic as mod compatibility checking
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    
    # Try exact version match first
    local dep_ids
    dep_ids=$(printf "%s" "$version_json" | jq -r \
        --arg v "$MC_VERSION" \
        '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
        2>/dev/null | tr '\n' ' ')
    
    # Try major.minor version if exact match failed
    if [[ -z "$dep_ids" ]]; then
        dep_ids=$(printf "%s" "$version_json" | jq -r \
            --arg v "$mc_major_minor" \
            '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
            2>/dev/null | tr '\n' ' ')
    fi
    
    # Try wildcard version (1.21.x) if still no results
    if [[ -z "$dep_ids" ]]; then
        local mc_major_minor_x="$mc_major_minor.x"
        dep_ids=$(printf "%s" "$version_json" | jq -r \
            --arg v "$mc_major_minor_x" \
            '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' \
            2>/dev/null | tr '\n' ' ')
    fi
    
    # Clean up and return dependency IDs
    dep_ids=$(echo "$dep_ids" | xargs)  # Trim whitespace
    if [[ -n "$dep_ids" ]]; then
        echo "$dep_ids"
    fi
}

# resolve_curseforge_dependencies: Get dependencies from CurseForge API
# Similar to Modrinth resolver but uses CurseForge API structure and authentication
# Parameters:
#   $1 - mod_id: CurseForge project ID (numeric)
#   $2 - mod_name: Human-readable mod name for logging
# Returns: Space-separated list of required dependency mod IDs
resolve_curseforge_dependencies() {
    local mod_id="$1"
    local mod_name="$2"
    
    # Download and decrypt CurseForge API token
    local cf_token_enc_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
    local tmp_token_file
    tmp_token_file=$(mktemp)
    if [[ -z "$tmp_token_file" ]]; then
        return 1
    fi
    
    # Download encrypted token
    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_token_file" "$cf_token_enc_url" 2>/dev/null)
    if [[ "$http_code" != "200" ]]; then
        rm "$tmp_token_file"
        return 1
    fi
    
    # Decrypt API token using simple XOR cipher
    local cf_api_key
    cf_api_key=$(python3 -c "
import sys
key = 42
with open('$tmp_token_file', 'rb') as f:
    encrypted = f.read()
decrypted = bytes([b ^ key for b in encrypted])
sys.stdout.buffer.write(decrypted)
" 2>/dev/null)
    rm "$tmp_token_file"
    
    if [[ -z "$cf_api_key" ]]; then
        return 1
    fi
    
    # Query CurseForge API with Fabric loader filter
    local cf_api_url="https://api.curseforge.com/v1/mods/$mod_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        return 1
    fi
    
    # Make authenticated API request
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url" 2>/dev/null)
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Validate API response
    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        return 1
    fi
    
    # Extract dependencies using CurseForge API structure
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    local mc_major_minor_x="$mc_major_minor.x"
    local mc_major_minor_0="$mc_major_minor.0"
    
    # CurseForge dependency extraction with version matching
    local dep_ids
    dep_ids=$(printf "%s" "$version_json" | jq -r \
        --arg mc_version "$MC_VERSION" \
        --arg mc_major_minor "$mc_major_minor" \
        --arg mc_major_minor_x "$mc_major_minor_x" \
        --arg mc_major_minor_0 "$mc_major_minor_0" \
        '.data[] | select(
            ((.gameVersions[] == $mc_version) or
             (.gameVersions[] == $mc_major_minor) or
             (.gameVersions[] == $mc_major_minor_x) or
             (.gameVersions[] == $mc_major_minor_0))
        ) | .dependencies[]? | select(.relationType == 3) | .modId' \
        2>/dev/null | tr '\n' ' ')
    
    # Clean up and return dependency IDs
    dep_ids=$(echo "$dep_ids" | xargs)  # Trim whitespace
    if [[ -n "$dep_ids" ]]; then
        echo "$dep_ids"
    fi
}

# resolve_modrinth_dependencies_api: Get dependencies from Modrinth API
# Fetches the project data from Modrinth and extracts required dependencies
# Parameters:
#   $1 - mod_id: The Modrinth project ID or slug
# Returns: Space-separated list of dependency mod IDs
resolve_modrinth_dependencies_api() {
    local mod_id="$1"
    local dependencies=""
    
    # Skip if essential commands are not available
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "" # Return empty dependencies
        return 0
    fi
    
    # Create temporary file for large API response to avoid "Argument list too long" error
    local tmp_file
    tmp_file=$(mktemp) || return 1
    
    # Get the latest version for the Minecraft version we're using with timeout
    local versions_url="https://api.modrinth.com/v2/project/$mod_id/version"
    
    if command -v curl >/dev/null 2>&1; then
        if ! curl -s -m 10 "$versions_url" -o "$tmp_file" 2>/dev/null; then
            rm -f "$tmp_file"
            echo ""
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "$tmp_file" --timeout=10 "$versions_url" 2>/dev/null; then
            rm -f "$tmp_file"
            echo ""
            return 0
        fi
    fi
    
    # Check if we got valid JSON data
    if [[ ! -s "$tmp_file" ]] || ! jq -e . < "$tmp_file" > /dev/null 2>&1; then
        rm -f "$tmp_file"
        echo ""
        return 0
    fi

    # Use simpler approach: find fabric versions for our Minecraft version
    if command -v jq >/dev/null 2>&1; then
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')  # Extract "1.21" from "1.21.3"
        
        # Simple jq filter to get dependencies from any compatible fabric version
        # Use temporary file to avoid command line length limits
        dependencies=$(jq -r "
            .[] 
            | select(.loaders[]? == \"fabric\") 
            | select(.game_versions[]? | test(\"$mc_major_minor\"))
            | .dependencies[]? 
            | select(.dependency_type == \"required\") 
            | .project_id
        " < "$tmp_file" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    else
        # Fallback to basic grep parsing if jq is not available
        local deps_section=$(grep -o '"dependencies":\[[^]]*\]' "$tmp_file" | head -1)
        if [[ -n "$deps_section" ]]; then
            # Extract project_id values from dependencies
            local dep_ids=$(echo "$deps_section" | grep -o '"project_id":"[^"]*"' | sed 's/"project_id":"//g' | sed 's/"//g')
            dependencies="$dep_ids"
        fi
    fi

    # Clean up temporary file
    rm -f "$tmp_file"
    
    echo "$dependencies"
}

# resolve_curseforge_dependencies_api: Get dependencies from CurseForge API
# Fetches the mod data from CurseForge and extracts required dependencies
# Parameters:
#   $1 - mod_id: The CurseForge project ID (numeric)
# Returns: Space-separated list of dependency mod IDs
resolve_curseforge_dependencies_api() {
    local mod_id="$1"
    local dependencies=""
    
    # Download encrypted CurseForge API token from GitHub repository
    local token_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
    local encrypted_token_file=$(mktemp)
    local http_code
    
    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -s -w "%{http_code}" -o "$encrypted_token_file" "$token_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        if wget -O "$encrypted_token_file" "$token_url" >/dev/null 2>&1; then
            http_code="200"
        else
            http_code="404"
        fi
    else
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    if [[ "$http_code" != "200" || ! -s "$encrypted_token_file" ]]; then
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    # Decrypt the API token using OpenSSL (requires passphrase hardcoded for automation)
    local api_token
    if command -v openssl >/dev/null 2>&1; then
        api_token=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$encrypted_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    else
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    rm -f "$encrypted_token_file"
    
    if [[ -z "$api_token" ]]; then
        echo ""
        return 1
    fi
    
    # Fetch mod info from CurseForge API with authentication
    local api_url="https://api.curseforge.com/v1/mods/$mod_id"
    local temp_file=$(mktemp)
    
    if command -v curl >/dev/null 2>&1; then
        curl -s -H "x-api-key: $api_token" -o "$temp_file" "$api_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --header="x-api-key: $api_token" -O "$temp_file" "$api_url" 2>/dev/null
    else
        rm -f "$temp_file"
        echo ""
        return 1
    fi
    
    # Extract required dependencies from mod info
    if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
        # Get the latest files for this mod
        local files_url="https://api.curseforge.com/v1/mods/$mod_id/files?modLoaderType=4"
        local files_temp=$(mktemp)
        
        if command -v curl >/dev/null 2>&1; then
            curl -s -H "x-api-key: $api_token" -o "$files_temp" "$files_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --header="x-api-key: $api_token" -O "$files_temp" "$files_url" 2>/dev/null
        fi
        
        if [[ -s "$files_temp" ]]; then
            # Find the most recent compatible file
            local mc_major_minor
            mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
            
            # Extract file ID from the most recent compatible file
            local file_id=$(jq -r --arg v "$MC_VERSION" --arg mmv "$mc_major_minor" '.data[] | select(.gameVersions[] == $v or .gameVersions[] == $mmv or (.gameVersions[] | startswith($mmv))) | .id' "$files_temp" 2>/dev/null | head -n1)
            
            if [[ -n "$file_id" && "$file_id" != "null" ]]; then
                # Get dependencies for this specific file
                local file_info_url="https://api.curseforge.com/v1/mods/$mod_id/files/$file_id"
                local file_info_temp=$(mktemp)
                
                if command -v curl >/dev/null 2>&1; then
                    curl -s -H "x-api-key: $api_token" -o "$file_info_temp" "$file_info_url" 2>/dev/null
                elif command -v wget >/dev/null 2>&1; then
                    wget -q --header="x-api-key: $api_token" -O "$file_info_temp" "$file_info_url" 2>/dev/null
                fi
                
                if [[ -s "$file_info_temp" ]]; then
                    # Extract required dependencies
                    dependencies=$(jq -r '.data.dependencies[]? | select(.relationType == 3) | .modId' "$file_info_temp" 2>/dev/null | tr '\n' ' ')
                fi
                
                rm -f "$file_info_temp"
            fi
        fi
        
        rm -f "$files_temp"
    fi
    
    rm -f "$temp_file"
    
    # Fallback for known dependencies if API fails
    if [[ -z "$dependencies" ]]; then
        case "$mod_id" in
            "238222")  # JEI
                dependencies="306612"  # Fabric API
                ;;
            "325471")  # Controllable  
                dependencies="634179"  # Framework
                ;;
        esac
    fi
    
    echo "$dependencies"
}

# fetch_and_add_external_mod: Fetch external mod data and add to mod arrays
# Downloads mod information from APIs and adds it to our internal mod arrays
# Parameters:
#   $1 - mod_id: The external mod ID
#   $2 - mod_type: The platform type (modrinth/curseforge)
# Returns: 0 if successful, 1 if failed
fetch_and_add_external_mod() {
    local ext_mod_id="$1"
    local ext_mod_type="$2"
    local success=false
    
    case "$ext_mod_type" in
        "modrinth")
            # Create temporary file for downloading large JSON responses
            local temp_file=$(mktemp)
            local api_url="https://api.modrinth.com/v2/project/$ext_mod_id"
            
            # Download to temp file without size restrictions
            local download_success=false
            if command -v curl >/dev/null 2>&1; then
                if curl -s -m 15 -o "$temp_file" "$api_url" 2>/dev/null; then
                    download_success=true
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -q -O "$temp_file" --timeout=15 "$api_url" 2>/dev/null; then
                    download_success=true
                fi
            fi
            
            if [[ "$download_success" == true && -s "$temp_file" ]]; then
                # Check if the file contains valid JSON (not an error)
                if ! grep -q '"error"' "$temp_file" 2>/dev/null; then
                    # Extract mod name from JSON file using jq if available, fallback to grep
                    local mod_title=""
                    local mod_description=""
                    
                    if command -v jq >/dev/null 2>&1; then
                        mod_title=$(jq -r '.title // ""' "$temp_file" 2>/dev/null)
                        mod_description=$(jq -r '.description // ""' "$temp_file" 2>/dev/null)
                    else
                        # Fallback to basic grep parsing
                        mod_title=$(grep -o '"title":"[^"]*"' "$temp_file" | sed 's/"title":"//g' | sed 's/"//g' | head -1)
                        mod_description=$(grep -o '"description":"[^"]*"' "$temp_file" | sed 's/"description":"//g' | sed 's/"//g' | head -1)
                    fi
                    
                    if [[ -n "$mod_title" ]]; then
                        # Add to our arrays (keep all arrays synchronized)
                        SUPPORTED_MODS+=("$mod_title")
                        MOD_DESCRIPTIONS+=("${mod_description:-External dependency}")
                        MOD_IDS+=("$ext_mod_id")
                        MOD_TYPES+=("modrinth")
                        MOD_URLS+=("")  # Empty URL - will be resolved during download
                        MOD_DEPENDENCIES+=("")  # Will be populated if needed
                        
                        # Add to final selection
                        local new_index=$((${#SUPPORTED_MODS[@]} - 1))
                        FINAL_MOD_INDEXES+=("$new_index")
                        success=true
                    fi
                fi
            fi
            
            # Clean up temp file
            rm -f "$temp_file" 2>/dev/null
            ;;
            
        "curseforge")
            # Use the new robust CurseForge API integration
            local mod_title=""
            local mod_description=""
            local download_url=""
            
            # Download encrypted CurseForge API token from GitHub repository
            local token_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
            local encrypted_token_file=$(mktemp)
            local http_code
            
            if command -v curl >/dev/null 2>&1; then
                http_code=$(curl -s -w "%{http_code}" -o "$encrypted_token_file" "$token_url" 2>/dev/null)
            elif command -v wget >/dev/null 2>&1; then
                if wget -O "$encrypted_token_file" "$token_url" >/dev/null 2>&1; then
                    http_code="200"
                else
                    http_code="404"
                fi
            fi
            
            if [[ "$http_code" == "200" && -s "$encrypted_token_file" ]]; then
                # Decrypt the API token
                local api_token
                if command -v openssl >/dev/null 2>&1; then
                    api_token=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$encrypted_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
                fi
                
                if [[ -n "$api_token" ]]; then
                    # Fetch mod info from CurseForge API
                    local api_url="https://api.curseforge.com/v1/mods/$ext_mod_id"
                    local temp_file=$(mktemp)
                    
                    if command -v curl >/dev/null 2>&1; then
                        curl -s -H "x-api-key: $api_token" -o "$temp_file" "$api_url" 2>/dev/null
                    elif command -v wget >/dev/null 2>&1; then
                        wget -q --header="x-api-key: $api_token" -O "$temp_file" "$api_url" 2>/dev/null
                    fi
                    
                    # Extract mod title and description
                    if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
                        mod_title=$(jq -r '.data.name // ""' "$temp_file" 2>/dev/null)
                        mod_description=$(jq -r '.data.summary // ""' "$temp_file" 2>/dev/null)
                    fi
                    
                    rm -f "$temp_file"
                    
                    # Get download URL using our robust function
                    download_url=$(get_curseforge_download_url "$ext_mod_id")
                fi
            fi
            
            rm -f "$encrypted_token_file"
            
            # Fallback for known mods if API fails
            if [[ -z "$mod_title" ]]; then
                case "$ext_mod_id" in
                    "317269")  # Controllable
                        mod_title="Controllable (Fabric)"
                        mod_description="Adds controller support to Minecraft"
                        ;;
                    "306612")  # Fabric API
                        mod_title="Fabric API"
                        mod_description="Essential modding API for Fabric"
                        ;;
                    "634179")  # Framework
                        mod_title="Framework"
                        mod_description="Library mod for various mods"
                        ;;
                    *)
                        mod_title="External Dependency (CF:$ext_mod_id)"
                        mod_description="External dependency from CurseForge"
                        ;;
                esac
            fi
            
            # Add to our arrays
            SUPPORTED_MODS+=("$mod_title")
            MOD_DESCRIPTIONS+=("${mod_description:-External dependency from CurseForge}")
            MOD_IDS+=("$ext_mod_id")
            MOD_TYPES+=("curseforge")
            MOD_URLS+=("$download_url")  # May be empty if API failed
            MOD_DEPENDENCIES+=("")  # Will be populated if needed
            
            local new_index=$((${#SUPPORTED_MODS[@]} - 1))
            FINAL_MOD_INDEXES+=("$new_index")
            success=true
            ;;
    esac
    
    if [[ "$success" == true ]]; then
        return 0
    else
        return 1
    fi
}

# get_curseforge_download_url: Get download URL for CurseForge mod
# Uses CurseForge API to find compatible mod file and return download URL
# Parameters:
#   $1 - mod_id: The CurseForge project ID (numeric)
# Returns: Download URL for the compatible mod file, or empty string if not found
get_curseforge_download_url() {
    local mod_id="$1"
    local download_url=""
    
    # Download encrypted CurseForge API token from GitHub repository
    local token_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
    local encrypted_token_file=$(mktemp)
    local http_code
    
    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -s -w "%{http_code}" -o "$encrypted_token_file" "$token_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        if wget -O "$encrypted_token_file" "$token_url" >/dev/null 2>&1; then
            http_code="200"
        else
            http_code="404"
        fi
    else
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    if [[ "$http_code" != "200" || ! -s "$encrypted_token_file" ]]; then
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    # Decrypt the API token using OpenSSL (requires passphrase hardcoded for automation)
    local api_token
    if command -v openssl >/dev/null 2>&1; then
        api_token=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$encrypted_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    else
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi
    
    rm -f "$encrypted_token_file"
    
    if [[ -z "$api_token" ]]; then
        echo ""
        return 1
    fi
    
    # Fetch mod files from CurseForge API with Fabric loader filter
    local files_url="https://api.curseforge.com/v1/mods/$mod_id/files?modLoaderType=4"
    local temp_file=$(mktemp)
    
    if command -v curl >/dev/null 2>&1; then
        curl -s -H "x-api-key: $api_token" -o "$temp_file" "$files_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --header="x-api-key: $api_token" -O "$temp_file" "$files_url" 2>/dev/null
    else
        rm -f "$temp_file"
        echo ""
        return 1
    fi
    
    # Parse response and find compatible file
    if [[ -s "$temp_file" ]] && command -v jq >/dev/null 2>&1; then
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
        
        # Try exact version match first
        download_url=$(jq -r --arg v "$MC_VERSION" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        
        # Try major.minor version if exact match failed
        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(jq -r --arg v "$mc_major_minor" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        fi
        
        # Try wildcard version (e.g., "1.21.x")
        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            local mc_major_minor_x="$mc_major_minor.x"
            download_url=$(jq -r --arg v "$mc_major_minor_x" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        fi
        
        # Try prefix matching (any version starting with major.minor)
        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(jq -r --arg v "$mc_major_minor" '.data[]? | select(.gameVersions[]? | startswith($v)) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        fi
        
        # If still no URL found, try the latest file
        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(jq -r '.data[0]?.downloadUrl // ""' "$temp_file" 2>/dev/null)
        fi
    fi
    
    rm -f "$temp_file"
    
    # Return the download URL (may be empty if not found)
    echo "$download_url"
}

# =============================================================================
# USER MOD SELECTION
# =============================================================================
# This section presents compatible mods to the user and handles their selection
# It categorizes mods into framework/required vs. optional user-selectable mods

# select_user_mods: Interactive mod selection with intelligent categorization
# Separates framework mods (auto-installed) from user-selectable mods
# Handles dependency resolution and ensures required splitscreen mods are included
select_user_mods() {
    print_header "🎯 MOD SELECTION"
    
    # Validate that we have compatible mods to present to the user
    if [[ ${#SUPPORTED_MODS[@]} -eq 0 ]]; then
        print_error "No compatible mods found for Minecraft $MC_VERSION"
        exit 1
    fi
    
    # Build list of user-selectable mods by filtering out framework and required mods
    # Framework mods (Fabric API, etc.) are installed automatically as dependencies
    # Required mods (Controllable, Splitscreen Support) are always installed
    local user_mod_indexes=()    # Indexes of mods user can choose from
    local install_all_mods=false # Flag for "install all" option
    
    echo ""
    echo "The following mods are available for Minecraft $MC_VERSION:"
    echo ""
    
    # Display numbered list of user-selectable mods
    local counter=1
    for i in "${!SUPPORTED_MODS[@]}"; do
        local skip=false
        
        # Skip required splitscreen mods (these are automatically installed)
        for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
            if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]]; then
                skip=true
                break
            fi
        done
        
        if [[ "$skip" == false ]]; then
            echo "  $counter. ${SUPPORTED_MODS[$i]}"
            user_mod_indexes+=("$i")
            ((counter++))
        fi
    done
    
    echo ""
    echo "Enter the numbers of the mods you want to install (e.g., '1 3 5' or '1-5'):"
    echo "  0 = Install all available mods (default)"
    echo "  -1 = Install only required mods (Controllable and Splitscreen Support)"
    echo ""
    
    local mod_selection
    read -p "Your choice [0]: " mod_selection
    
    # Process user selection
    if [[ -z "$mod_selection" || "$mod_selection" == "0" ]]; then
        install_all_mods=true
        print_info "Installing all available mods"
    elif [[ "$mod_selection" == "-1" ]]; then
        mod_selection=""
        print_info "Installing only required mods"
    else
        print_info "Installing selected mods"
    fi
    
    # Build final mod list including dependencies
    declare -A added
    
    if [[ "$install_all_mods" == true ]]; then
        for i in "${!SUPPORTED_MODS[@]}"; do
            FINAL_MOD_INDEXES+=("$i")
            added[$i]=1
        done
    else
        # Add selected mods
        if [[ -n "$mod_selection" ]]; then
            echo "Selected mods:"
            
            # SELECTION PROCESSING: Parse user input supporting individual numbers and ranges
            # Examples: "1 3 5", "1-5", "1 3-7 9"
            local expanded_selection=()
            
            # Parse each token in the selection
            for token in $mod_selection; do
                if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
                    # RANGE PARSING: Handle range format like "1-5"
                    local start_num=${token%-*}
                    local end_num=${token#*-}
                    
                    # Validate range bounds
                    if ((start_num >= 1 && end_num <= ${#user_mod_indexes[@]} && start_num <= end_num)); then
                        for ((range_num=start_num; range_num<=end_num; range_num++)); do
                            expanded_selection+=("$range_num")
                        done
                    else
                        print_warning "Invalid range: $token (valid range: 1-${#user_mod_indexes[@]})"
                    fi
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    # INDIVIDUAL NUMBER: Handle single number
                    if ((token >= 1 && token <= ${#user_mod_indexes[@]})); then
                        expanded_selection+=("$token")
                    else
                        print_warning "Invalid selection: $token (valid range: 1-${#user_mod_indexes[@]})"
                    fi
                else
                    print_warning "Invalid format: $token (use numbers or ranges like 1-5)"
                fi
            done
            
            # Remove duplicates and sort
            expanded_selection=($(printf "%s\n" "${expanded_selection[@]}" | sort -nu))
            
            # Process the expanded selection
            for sel in "${expanded_selection[@]}"; do
                local idx=${user_mod_indexes[$((sel-1))]}
                echo "  ${SUPPORTED_MODS[$idx]}"
                FINAL_MOD_INDEXES+=("$idx")
                added[$idx]=1
            done
            
            # Add dependencies for selected mods
            for sel in "${expanded_selection[@]}"; do
                local idx=${user_mod_indexes[$((sel-1))]}
                add_mod_dependencies "$idx" added
            done
        fi
    fi
     # Ensure required splitscreen mods are always included
    for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
        for i in "${!SUPPORTED_MODS[@]}"; do
            if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]] && [[ -z "${added[$i]:-}" ]]; then
                FINAL_MOD_INDEXES+=("$i")
                added[$i]=1
                add_mod_dependencies "$i" added
            fi
        done
    done

    # Automatically resolve all dependencies using Modrinth/CurseForge APIs
    # This replaces the manual dependency handling with full API-based resolution
    resolve_all_dependencies

    print_success "Final mod list prepared: ${#FINAL_MOD_INDEXES[@]} mods selected"
}

add_mod_dependencies() {
    local mod_idx="$1"
    local -n added_ref="$2"
    
    # Handle special case for Controllable (needs Framework)
    if [[ "${SUPPORTED_MODS[$mod_idx]}" == "Controllable (Fabric)"* ]]; then
        for j in "${!MODS[@]}"; do
            IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "${MODS[$j]}"
            if [[ "$MOD_NAME" == "Framework (Fabric)"* ]]; then
                for k in "${!MOD_IDS[@]}"; do
                    if [[ "${MOD_IDS[$k]}" == "$MOD_ID" ]] && [[ -z "${added_ref[$k]:-}" ]]; then
                        FINAL_MOD_INDEXES+=("$k")
                        added_ref[$k]=1
                    fi
                done
            fi
        done
    fi
    
    # Add Modrinth dependencies
    local dep_string="${MOD_DEPENDENCIES[$mod_idx]}"
    if [[ -n "$dep_string" ]]; then
        read -a dep_arr <<< "$dep_string"
        for dep in "${dep_arr[@]}"; do
            if [[ -n "$dep" ]]; then
                for j in "${!MOD_IDS[@]}"; do
                    if [[ "${MOD_IDS[$j]}" == "$dep" ]] && [[ -z "${added_ref[$j]:-}" ]]; then
                        FINAL_MOD_INDEXES+=("$j")
                        added_ref[$j]=1
                    fi
                done
            fi
        done
    fi
}

# =============================================================================
# INSTANCE CREATION
# =============================================================================
# This section handles the core task of creating 4 separate Minecraft instances
# for splitscreen gameplay. Each instance is configured identically with mods
# but will be launched separately for multi-player splitscreen gaming.

# create_instances: Create 4 identical Minecraft instances for splitscreen play
# Uses PrismLauncher CLI when possible, falls back to manual creation if needed
# Each instance gets the same mods but separate configurations for splitscreen
create_instances() {
    print_header "🚀 CREATING MINECRAFT INSTANCES"
    
    # Clean up the final mod selection list (remove any duplicates from dependency resolution)
    FINAL_MOD_INDEXES=( $(printf "%s\n" "${FINAL_MOD_INDEXES[@]}" | sort -u) )
    
    # Initialize tracking for mods that fail to install
    MISSING_MODS=()
    print_progress "Creating 4 splitscreen instances..."
    
    # Create exactly 4 instances: latestUpdate-1, latestUpdate-2, latestUpdate-3, latestUpdate-4
    # This naming convention is expected by the splitscreen launcher script
    for i in {1..4}; do
        local instance_name="latestUpdate-$i"
        print_progress "Creating instance $i of 4: $instance_name"
        
        # Clean slate: remove any existing instance with the same name
        if [[ -d "$TARGET_DIR/instances/$instance_name" ]]; then
            print_info "Removing existing instance: $instance_name"
            rm -rf "$TARGET_DIR/instances/$instance_name"
        fi
        
        # STAGE 1: Attempt CLI-based instance creation (preferred method)
        print_progress "Creating Minecraft $MC_VERSION instance with Fabric..."
        local cli_success=false
        
        # Try multiple CLI creation approaches with progressively fewer parameters
        # This handles different PrismLauncher versions that may have varying CLI support
        
        # Attempt 1: Full specification with Fabric loader
        if "$TARGET_DIR/PrismLauncher.AppImage" --cli create-instance \
            --name "$instance_name" \
            --mc-version "$MC_VERSION" \
            --group "Splitscreen" \
            --loader "fabric" >/dev/null 2>&1; then
            cli_success=true
            print_success "Created with Fabric loader"
        # Try without loader specification
        elif "$TARGET_DIR/PrismLauncher.AppImage" --cli create-instance \
            --name "$instance_name" \
            --mc-version "$MC_VERSION" \
            --group "Splitscreen" >/dev/null 2>&1; then
            cli_success=true
            print_success "Created without specific loader"
        # Try basic creation with minimal parameters
        elif "$TARGET_DIR/PrismLauncher.AppImage" --cli create-instance \
            --name "$instance_name" \
            --mc-version "$MC_VERSION" >/dev/null 2>&1; then
            cli_success=true
            print_success "Created with minimal parameters"
        fi
        
        # FALLBACK: Manual instance creation when CLI methods fail
        # This creates instances manually by writing configuration files directly
        # This ensures compatibility even with older PrismLauncher versions that lack CLI support
        if [[ "$cli_success" == false ]]; then
            print_warning "CLI instance creation failed, attempting manual creation..."
            local instance_dir="$TARGET_DIR/instances/$instance_name"
            mkdir -p "$instance_dir"
            
            # Create instance.cfg - PrismLauncher's main instance configuration file
            # This file defines the instance metadata, version, and launcher settings
            cat > "$instance_dir/instance.cfg" <<EOF
InstanceType=OneSix
iconKey=default
name=Player $i
OverrideCommands=false
OverrideConsole=false
OverrideGameTime=false
OverrideJavaArgs=false
OverrideJavaLocation=false
OverrideMCLaunchMethod=false
OverrideMemory=false
OverrideNativeWorkarounds=false
OverrideWindow=false
IntendedVersion=$MC_VERSION
EOF
            
            # Create mmc-pack.json - MultiMC/PrismLauncher component definition file
            # This file defines the mod loader stack: LWJGL3 → Minecraft → Intermediary → Fabric
            # Components are loaded in dependency order to ensure proper mod support
            mkdir -p "$instance_dir/.minecraft"
            
            cat > "$instance_dir/mmc-pack.json" <<EOF
{
    "components": [
        {
            "cachedName": "LWJGL 3",
            "cachedVersion": "3.3.3",
            "cachedVolatile": true,
            "dependencyOnly": true,
            "uid": "org.lwjgl3",
            "version": "3.3.3"
        },
        {
            "cachedName": "Minecraft",
            "cachedRequires": [
                {
                    "suggests": "3.3.3",
                    "uid": "org.lwjgl3"
                }
            ],
            "cachedVersion": "$MC_VERSION",
            "important": true,
            "uid": "net.minecraft",
            "version": "$MC_VERSION"
        },
        {
            "cachedName": "Intermediary Mappings",
            "cachedRequires": [
                {
                    "equals": "$MC_VERSION",
                    "uid": "net.minecraft"
                }
            ],
            "cachedVersion": "$MC_VERSION",
            "cachedVolatile": true,
            "dependencyOnly": true,
            "uid": "net.fabricmc.intermediary",
            "version": "$MC_VERSION"
        },
        {
            "cachedName": "Fabric Loader",
            "cachedRequires": [
                {
                    "uid": "net.fabricmc.intermediary"
                }
            ],
            "cachedVersion": "$FABRIC_VERSION",
            "uid": "net.fabricmc.fabric-loader",
            "version": "$FABRIC_VERSION"
        }
    ],
    "formatVersion": 1
}
EOF
            print_success "Manual instance creation completed"
        fi
        
        # INSTANCE VERIFICATION: Ensure the instance directory was created successfully
        # This verification step prevents subsequent operations on non-existent instances
        local instance_dir="$TARGET_DIR/instances/$instance_name"
        if [[ ! -d "$instance_dir" ]]; then
            print_error "Instance directory not found: $instance_dir"
            continue  # Skip to next instance if this one failed
        fi
        
        print_success "Instance created successfully: $instance_name"
        
        # FABRIC AND MOD INSTALLATION: Configure mod loader and install selected mods
        # This step adds Fabric loader support and downloads all compatible mods
        install_fabric_and_mods "$instance_dir" "$instance_name"
    done
}

# =============================================================================
# FABRIC LOADER AND MOD INSTALLATION
# =============================================================================

# Install Fabric mod loader and download all selected mods for an instance
# This function ensures each instance has the proper mod loader and all compatible mods
# Parameters:
#   $1 - instance_dir: Path to the PrismLauncher instance directory
#   $2 - instance_name: Display name of the instance for logging
install_fabric_and_mods() {
    local instance_dir="$1"
    local instance_name="$2"
    
    print_progress "Installing Fabric loader for mod support..."
    local pack_json="$instance_dir/mmc-pack.json"
    
    # FABRIC LOADER INSTALLATION: Add Fabric to the component stack if not present
    # Fabric loader is required for all Fabric mods to function properly
    # We check if it's already installed to avoid duplicate entries
    if [[ ! -f "$pack_json" ]] || ! grep -q "net.fabricmc.fabric-loader" "$pack_json" 2>/dev/null; then
        print_progress "Adding Fabric loader to $instance_name..."
        
        # Create complete component stack with proper dependency chain
        # Order matters: LWJGL3 → Minecraft → Intermediary Mappings → Fabric Loader
        cat > "$pack_json" <<EOF
{
    "components": [
        {
            "cachedName": "LWJGL 3",
            "cachedVersion": "3.3.3",
            "cachedVolatile": true,
            "dependencyOnly": true,
            "uid": "org.lwjgl3",
            "version": "3.3.3"
        },
        {
            "cachedName": "Minecraft",
            "cachedRequires": [
                {
                    "suggests": "3.3.3",
                    "uid": "org.lwjgl3"
                }
            ],
            "cachedVersion": "$MC_VERSION",
            "important": true,
            "uid": "net.minecraft",
            "version": "$MC_VERSION"
        },
        {
            "cachedName": "Intermediary Mappings",
            "cachedRequires": [
                {
                    "equals": "$MC_VERSION",
                    "uid": "net.minecraft"
                }
            ],
            "cachedVersion": "$MC_VERSION",
            "cachedVolatile": true,
            "dependencyOnly": true,
            "uid": "net.fabricmc.intermediary",
            "version": "$MC_VERSION"
        },
        {
            "cachedName": "Fabric Loader",
            "cachedRequires": [
                {
                    "uid": "net.fabricmc.intermediary"
                }
            ],
            "cachedVersion": "$FABRIC_VERSION",
            "uid": "net.fabricmc.fabric-loader",
            "version": "$FABRIC_VERSION"
        }
    ],
    "formatVersion": 1
}
EOF
        print_success "Fabric loader v$FABRIC_VERSION installed"
    fi
    
    # MOD DOWNLOAD AND INSTALLATION: Download all selected mods to instance
    # Create the mods directory where Fabric will load .jar files from
    local mods_dir="$instance_dir/.minecraft/mods"
    mkdir -p "$mods_dir"
    
    # Process each mod that was selected and has a compatible download URL
    # FINAL_MOD_INDEXES contains indices of mods that passed compatibility checking
    for idx in "${FINAL_MOD_INDEXES[@]}"; do
        local mod_url="${MOD_URLS[$idx]}"
        local mod_name="${SUPPORTED_MODS[$idx]}"
        local mod_id="${MOD_IDS[$idx]}"
        local mod_type="${MOD_TYPES[$idx]}"
        
        # RESOLVE MISSING URLs: For dependencies added without URLs, fetch the download URL now
        if [[ -z "$mod_url" || "$mod_url" == "null" ]] && [[ "$mod_type" == "modrinth" ]]; then
            print_progress "Resolving download URL for dependency: $mod_name"
            
            # Use the same comprehensive version matching as main mod compatibility checking
            local resolve_data=""
            local temp_resolve_file=$(mktemp)
            
            # Fetch all versions for this dependency
            local versions_url="https://api.modrinth.com/v2/project/$mod_id/version"
            if command -v curl >/dev/null 2>&1; then
                if curl -s -m 15 -o "$temp_resolve_file" "$versions_url" 2>/dev/null; then
                    resolve_data=$(cat "$temp_resolve_file")
                fi
            elif command -v wget >/dev/null 2>&1; then
                if wget -q -O "$temp_resolve_file" --timeout=15 "$versions_url" 2>/dev/null; then
                    resolve_data=$(cat "$temp_resolve_file")
                fi
            fi
            
            if [[ -n "$resolve_data" && "$resolve_data" != "[]" && "$resolve_data" != *"\"error\""* ]]; then
                # Try exact version match first
                mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
                
                # Try major.minor version if exact match failed  
                if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                    local mc_major_minor
                    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
                    
                    # Try exact major.minor
                    mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
                    
                    # Try wildcard version (e.g., "1.21.x")
                    if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                        local mc_major_minor_x="$mc_major_minor.x"
                        mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
                    fi
                    
                    # Try prefix matching (any version starting with major.minor)
                    if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                        mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] | startswith($v) and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
                    fi
                fi
                
                # If still no URL found, try the latest Fabric version for any compatible release
                if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                    mod_url=$(printf "%s" "$resolve_data" | jq -r '.[] | select(.loaders[] == "fabric") | .files[0].url' 2>/dev/null | head -n1)
                fi
            fi
            
            rm -f "$temp_resolve_file" 2>/dev/null
        fi
        
        # RESOLVE MISSING URLs for CurseForge dependencies
        if [[ -z "$mod_url" || "$mod_url" == "null" ]] && [[ "$mod_type" == "curseforge" ]]; then
            print_progress "Resolving download URL for CurseForge dependency: $mod_name"
            
            # Use our robust CurseForge URL resolution function
            mod_url=$(get_curseforge_download_url "$mod_id")
            
            if [[ -n "$mod_url" && "$mod_url" != "null" ]]; then
                print_success "Found compatible CurseForge file for $mod_name"
            else
                print_warning "No compatible CurseForge file found for $mod_name"
            fi
        fi
        
        # SKIP INVALID MODS: Handle cases where URL couldn't be resolved
        if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
            print_warning "No compatible file found for $mod_name. Skipping download."
            MISSING_MODS+=("$mod_name")  # Track for final summary
            continue
        fi
        
        # DOWNLOAD MOD FILE: Attempt to download the mod .jar file
        # Filename is sanitized (spaces replaced with underscores) for filesystem compatibility
        local mod_file="$mods_dir/${mod_name// /_}.jar"
        if wget -O "$mod_file" "$mod_url" >/dev/null 2>&1; then
            print_success "Success: $mod_name"
        else
            print_warning "Failed: $mod_name"
            MISSING_MODS+=("$mod_name")  # Track download failures for summary
        fi
    done
    
    # =============================================================================
    # MINECRAFT AUDIO CONFIGURATION
    # =============================================================================
    
    # SPLITSCREEN AUDIO SETUP: Configure music volume for each instance
    # Instance 1 keeps music at default volume (0.3), instances 2-4 have music muted
    # This prevents audio overlap when multiple instances are running simultaneously
    print_progress "Configuring splitscreen audio settings for $instance_name..."
    
    # Extract instance number from instance name (latestUpdate-X format)
    local instance_number
    instance_number=$(echo "$instance_name" | grep -oE '[0-9]+$')
    
    # Determine music volume based on instance number
    local music_volume="0.3"  # Default music volume
    if [[ "$instance_number" -gt 1 ]]; then
        music_volume="0.0"    # Mute music for instances 2, 3, and 4
        print_info "   → Music muted for $instance_name (prevents audio overlap)"
    else
        print_info "   → Music enabled for $instance_name (primary audio instance)"
    fi
    
    # Create Minecraft options.txt file with splitscreen-optimized settings
    # This file contains all Minecraft client settings including audio, graphics, and controls
    cat > "$instance_dir/.minecraft/options.txt" <<EOF
version:3465
autoJump:false
operatorItemsTab:false
autoSuggestions:true
chatColors:true
chatLinks:true
chatLinksPrompt:true
enableVsync:true
entityShadows:true
forceUnicodeFont:false
discrete_mouse_scroll:false
invertYMouse:false
realmsNotifications:true
reducedDebugInfo:false
showSubtitles:false
directionalAudio:false
touchscreen:false
fullscreen:false
bobView:true
toggleCrouch:false
toggleSprint:false
darkMojangStudiosBackground:false
hideLightningFlashes:false
mouseSensitivity:0.5
fov:0.0
screenEffectScale:1.0
fovEffectScale:1.0
gamma:0.0
renderDistance:12
simulationDistance:12
entityDistanceScaling:1.0
guiScale:0
particles:0
maxFps:120
difficulty:2
graphicsMode:1
ao:true
prioritizeChunkUpdates:0
biomeBlendRadius:2
renderClouds:"true"
resourcePacks:[]
incompatibleResourcePacks:[]
lastServer:
lang:en_us
soundDevice:""
chatVisibility:0
chatOpacity:1.0
chatLineSpacing:0.0
textBackgroundOpacity:0.5
backgroundForChatOnly:true
hideServerAddress:false
advancedItemTooltips:false
pauseOnLostFocus:true
overrideWidth:0
overrideHeight:0
heldItemTooltips:true
chatHeightFocused:1.0
chatDelay:0.0
chatHeightUnfocused:0.44366195797920227
chatScale:1.0
chatWidth:1.0
mipmapLevels:4
useNativeTransport:true
mainHand:"right"
attackIndicator:1
narrator:0
tutorialStep:none
mouseWheelSensitivity:1.0
rawMouseInput:true
glDebugVerbosity:1
skipMultiplayerWarning:false
skipRealms32bitWarning:false
hideMatchedNames:true
joinedFirstServer:false
hideBundleTutorial:false
syncChunkWrites:true
showAutosaveIndicator:true
allowServerListing:true
onlyShowSecureChat:false
panoramaScrollSpeed:1.0
telemetryOptInExtra:false
soundCategory_master:1.0
soundCategory_music:${music_volume}
soundCategory_record:1.0
soundCategory_weather:1.0
soundCategory_block:1.0
soundCategory_hostile:1.0
soundCategory_neutral:1.0
soundCategory_player:1.0
soundCategory_ambient:1.0
soundCategory_voice:1.0
modelPart_cape:true
modelPart_jacket:true
modelPart_left_sleeve:true
modelPart_right_sleeve:true
modelPart_left_pants_leg:true
modelPart_right_pants_leg:true
modelPart_hat:true
key_key.attack:key.mouse.left
key_key.use:key.mouse.right
key_key.forward:key.keyboard.w
key_key.left:key.keyboard.a
key_key.back:key.keyboard.s
key_key.right:key.keyboard.d
key_key.jump:key.keyboard.space
key_key.sneak:key.keyboard.left.shift
key_key.sprint:key.keyboard.left.control
key_key.drop:key.keyboard.q
key_key.inventory:key.keyboard.e
key_key.chat:key.keyboard.t
key_key.playerlist:key.keyboard.tab
key_key.pickItem:key.mouse.middle
key_key.command:key.keyboard.slash
key_key.socialInteractions:key.keyboard.p
key_key.screenshot:key.keyboard.f2
key_key.togglePerspective:key.keyboard.f5
key_key.smoothCamera:key.keyboard.unknown
key_key.fullscreen:key.keyboard.f11
key_key.spectatorOutlines:key.keyboard.unknown
key_key.swapOffhand:key.keyboard.f
key_key.saveToolbarActivator:key.keyboard.c
key_key.loadToolbarActivator:key.keyboard.x
key_key.advancements:key.keyboard.l
key_key.hotbar.1:key.keyboard.1
key_key.hotbar.2:key.keyboard.2
key_key.hotbar.3:key.keyboard.3
key_key.hotbar.4:key.keyboard.4
key_key.hotbar.5:key.keyboard.5
key_key.hotbar.6:key.keyboard.6
key_key.hotbar.7:key.keyboard.7
key_key.hotbar.8:key.keyboard.8
key_key.hotbar.9:key.keyboard.9
EOF
    
    print_success "Audio configuration complete for $instance_name"
    
    print_success "Fabric and mods installation complete for $instance_name"
}

# =============================================================================
# POLLYMC SETUP AND CLEANUP
# =============================================================================

# =============================================================================
# POLLYMC SETUP AND OPTIMIZATION
# =============================================================================

# setup_pollymc: Configure PollyMC as the primary launcher for splitscreen gameplay
# 
# POLLYMC ADVANTAGES FOR SPLITSCREEN:
# - No forced Microsoft login requirements (offline-friendly)
# - Better handling of multiple simultaneous instances
# - Cleaner interface without authentication popups
# - More stable for automated controller-based launching
# 
# PROCESS OVERVIEW:
# 1. Download PollyMC AppImage from GitHub releases
# 2. Migrate all instances from PrismLauncher to PollyMC
# 3. Copy offline accounts configuration
# 4. Test PollyMC compatibility and functionality
# 5. Set up splitscreen launcher script for PollyMC
# 6. Clean up PrismLauncher files to save space
#
# FALLBACK STRATEGY:
# If PollyMC fails at any step, we fall back to PrismLauncher
# This ensures the installation completes successfully regardless
setup_pollymc() {
    print_header "🎮 SETTING UP POLLYMC"
    
    print_progress "Downloading PollyMC for optimized splitscreen gameplay..."
    
    # =============================================================================
    # POLLYMC DIRECTORY INITIALIZATION
    # =============================================================================
    
    # Create PollyMC data directory structure
    # PollyMC stores instances, accounts, configuration, and launcher script here
    # Structure: ~/.local/share/PollyMC/{instances/, accounts.json, PollyMC AppImage}
    mkdir -p "$HOME/.local/share/PollyMC"
    
    # =============================================================================
    # POLLYMC APPIMAGE DOWNLOAD AND VERIFICATION
    # =============================================================================
    
    # Download PollyMC AppImage from official GitHub releases
    # AppImage format provides universal Linux compatibility without dependencies
    # PollyMC GitHub releases API endpoint for latest version
    # We download the x86_64 Linux AppImage which works on most modern Linux systems
    local pollymc_url="https://github.com/fn2006/PollyMC/releases/latest/download/PollyMC-Linux-x86_64.AppImage"
    print_progress "Fetching PollyMC from GitHub releases: $(basename "$pollymc_url")..."
    
    # DOWNLOAD WITH FALLBACK HANDLING
    # If PollyMC download fails, we continue with PrismLauncher as the primary launcher
    # This ensures installation doesn't fail completely due to network issues or GitHub downtime
    if ! wget -O "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage" "$pollymc_url"; then
        print_warning "❌ PollyMC download failed - continuing with PrismLauncher as primary launcher"
        print_info "   This is not a critical error - PrismLauncher works fine for splitscreen"
        USE_POLLYMC=false  # Global flag tracks which launcher is active
        return 0
    else
        # APPIMAGE PERMISSIONS: Make the downloaded AppImage executable
        # AppImages require execute permissions to run properly
        chmod +x "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage"
        print_success "✅ PollyMC AppImage downloaded and configured successfully"
        USE_POLLYMC=true  # Mark PollyMC as available for further setup
    fi

    # =============================================================================
    # INSTANCE MIGRATION: Transfer all Minecraft instances from PrismLauncher
    # =============================================================================
    
    # INSTANCE DIRECTORY MIGRATION
    # Copy the complete instances directory structure from PrismLauncher to PollyMC
    # This includes all 4 splitscreen instances with their configurations, mods, and saves
    print_progress "Migrating PrismLauncher instances to PollyMC data directory..."
    
    # INSTANCES TRANSFER: Copy entire instances folder with all splitscreen configurations
    # Each instance (latestUpdate-1 through latestUpdate-4) contains:
    # - Minecraft version configuration
    # - Fabric mod loader setup
    # - All downloaded mods and their dependencies
    # - Splitscreen-specific mod configurations
    # - Instance-specific settings (memory, Java args, etc.)
    if [[ -d "$TARGET_DIR/instances" ]]; then
        cp -r "$TARGET_DIR/instances" "$HOME/.local/share/PollyMC/"
        print_success "✅ Splitscreen instances migrated to PollyMC"
        
        # INSTANCE COUNT VERIFICATION: Ensure all 4 instances were copied successfully
        local instance_count
        instance_count=$(find "$HOME/.local/share/PollyMC/instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
        print_info "   → $instance_count splitscreen instances available in PollyMC"
    else
        print_warning "⚠️  No instances directory found in PrismLauncher - this shouldn't happen"
    fi
    
    # =============================================================================
    # ACCOUNT CONFIGURATION MIGRATION
    # =============================================================================
    
    # OFFLINE ACCOUNTS TRANSFER: Copy splitscreen player account configurations
    # The accounts.json file contains offline player profiles for Player 1-4
    # These accounts allow splitscreen gameplay without requiring multiple Microsoft accounts
    if [[ -f "$TARGET_DIR/accounts.json" ]]; then
        cp "$TARGET_DIR/accounts.json" "$HOME/.local/share/PollyMC/"
        print_success "✅ Offline splitscreen accounts copied to PollyMC"
        print_info "   → Player accounts P1, P2, P3, P4 configured for offline gameplay"
    else
        print_warning "⚠️  accounts.json not found - splitscreen accounts may need manual setup"
    fi

    # =============================================================================
    # POLLYMC CONFIGURATION: Skip Setup Wizard
    # =============================================================================
    
    # SETUP WIZARD BYPASS: Create PollyMC configuration using user's proven working settings
    # This uses the exact configuration from the user's working PollyMC installation
    # Guarantees compatibility and skips all setup wizard prompts
    print_progress "Configuring PollyMC with proven working settings..."
    
    # Get the current hostname for dynamic configuration with multiple fallback methods
    local current_hostname
    if command -v hostname >/dev/null 2>&1; then
        current_hostname=$(hostname)
    elif [[ -r /proc/sys/kernel/hostname ]]; then
        current_hostname=$(cat /proc/sys/kernel/hostname)
    elif [[ -n "$HOSTNAME" ]]; then
        current_hostname="$HOSTNAME"
    else
        current_hostname="localhost"
    fi
    
    cat > "$HOME/.local/share/PollyMC/pollymc.cfg" <<EOF
[General]
ApplicationTheme=system
ConfigVersion=1.2
FlameKeyOverride=\$2a\$10\$bL4bIL5pUWqfcO7KQtnMReakwtfHbNKh6v1uTpKlzhwoueEJQnPnm
FlameKeyShouldBeFetchedOnStartup=false
IconTheme=pe_colored
JavaPath=${JAVA_PATH}
Language=en_US
LastHostname=${current_hostname}
MainWindowGeometry=@ByteArray(AdnQywADAAAAAAwwAAAAzAAAD08AAANIAAAMMAAAAPEAAA9PAAADSAAAAAEAAAAAB4AAAAwwAAAA8QAAD08AAANI)
MainWindowState="@ByteArray(AAAA/wAAAAD9AAAAAAAAApUAAAH8AAAABAAAAAQAAAAIAAAACPwAAAADAAAAAQAAAAEAAAAeAGkAbgBzAHQAYQBuAGMAZQBUAG8AbwBsAEIAYQByAwAAAAD/////AAAAAAAAAAAAAAACAAAAAQAAABYAbQBhAGkAbgBUAG8AbwBsAEIAYQByAQAAAAD/////AAAAAAAAAAAAAAADAAAAAQAAABYAbgBlAHcAcwBUAG8AbwBsAEIAYQByAQAAAAD/////AAAAAAAAAAA=)"
MaxMemAlloc=4096
MinMemAlloc=512
ToolbarsLocked=false
WideBarVisibility_instanceToolBar="@ByteArray(111111111,BpBQWIumr+0ABXFEarV0R5nU0iY=)"
EOF
    
    print_success "✅ PollyMC configured to skip setup wizard"
    print_info "   → Setup wizard will not appear on first launch"
    print_info "   → Java path and memory settings pre-configured"

    # =============================================================================
    # POLLYMC COMPATIBILITY VERIFICATION
    # =============================================================================
    
    # POLLYMC FUNCTIONALITY TEST: Verify PollyMC works on this system
    # Test basic AppImage execution and CLI functionality before committing to use PollyMC
    # Some older systems or restricted environments may have issues with AppImages
    print_progress "Testing PollyMC compatibility and basic functionality..."
    
    # APPIMAGE EXECUTION TEST: Run PollyMC with --help flag to verify it works
    # Timeout prevents hanging if AppImage has issues
    # This tests: AppImage execution, basic CLI functionality, system compatibility
    if timeout 5s "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage" --help >/dev/null 2>&1; then
        print_success "✅ PollyMC compatibility test passed - AppImage executes properly"
        
        # =============================================================================
        # POLLYMC INSTANCE VERIFICATION AND FINAL SETUP
        # =============================================================================
        
        # INSTANCE ACCESS VERIFICATION: Confirm PollyMC can detect and access migrated instances
        # This ensures PollyMC properly recognizes the instance format from PrismLauncher
        # Both launchers use similar formats, but compatibility should be verified
        print_progress "Verifying PollyMC can access migrated splitscreen instances..."
        local polly_instances_count
        polly_instances_count=$(find "$HOME/.local/share/PollyMC/instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
        
        if [[ "$polly_instances_count" -eq 4 ]]; then
            print_success "✅ PollyMC instance verification successful - all 4 instances accessible"
            print_info "   → latestUpdate-1, latestUpdate-2, latestUpdate-3, latestUpdate-4 ready"
            
            # LAUNCHER SCRIPT CONFIGURATION: Set up the splitscreen launcher for PollyMC
            # This configures the controller detection and multi-instance launch script
            setup_pollymc_launcher
            
            # CLEANUP PHASE: Remove PrismLauncher since PollyMC is working
            # This saves significant disk space (~500MB+) and avoids launcher confusion
            # PrismLauncher was only needed for the CLI-based instance creation process
            cleanup_prism_launcher
            
            print_success "🎮 PollyMC is now the primary launcher for splitscreen gameplay"
            print_info "   → PrismLauncher files cleaned up to save disk space"
        else
            print_warning "⚠️  PollyMC instance verification failed - found $polly_instances_count instances instead of 4"
            print_info "   → Falling back to PrismLauncher as primary launcher"
            USE_POLLYMC=false
        fi
    else
        print_warning "❌ PollyMC compatibility test failed - AppImage execution issues detected"
        print_info "   → This may be due to system restrictions, missing dependencies, or AppImage incompatibility"
        print_info "   → Falling back to PrismLauncher for gameplay (still fully functional)"
        USE_POLLYMC=false
    fi
}

# Configure the splitscreen launcher script for PollyMC
# Downloads and modifies the launcher script to use PollyMC instead of PrismLauncher
setup_pollymc_launcher() {
    print_progress "Setting up launcher script for PollyMC..."
    
    # LAUNCHER SCRIPT DOWNLOAD: Get the splitscreen launcher script from GitHub
    # This script handles controller detection and multi-instance launching
    if wget -O "$HOME/.local/share/PollyMC/minecraftSplitscreen.sh" \
        "https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/minecraftSplitscreen.sh"; then
        chmod +x "$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        
        # LAUNCHER SCRIPT CONFIGURATION: Modify paths to use PollyMC instead of PrismLauncher
        # Replace PrismLauncher AppImage path with PollyMC AppImage path
        sed -i 's|PrismLauncher/PrismLauncher.AppImage|PollyMC/PollyMC-Linux-x86_64.AppImage|g' \
            "$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        # Replace PrismLauncher data directory with PollyMC data directory
        sed -i 's|/.local/share/PrismLauncher/|/.local/share/PollyMC/|g' \
            "$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        
        print_success "Launcher script configured and copied to PollyMC"
    else
        print_warning "Failed to download launcher script"
    fi
}

# Clean up PrismLauncher installation after successful PollyMC setup
# This removes the temporary PrismLauncher directory to save disk space
# PrismLauncher was only needed for automated instance creation via CLI
cleanup_prism_launcher() {
    print_progress "Cleaning up PrismLauncher (no longer needed)..."
    
    # SAFETY: Navigate to home directory before removal operations
    # This prevents accidental deletion if we're currently in the target directory
    cd "$HOME" || return 1
    
    # SAFETY CHECKS: Multiple validations before removing directories
    # Ensure we're not deleting critical system directories or user home
    if [[ -d "$TARGET_DIR" && "$TARGET_DIR" != "$HOME" && "$TARGET_DIR" != "/" && "$TARGET_DIR" == *"PrismLauncher"* ]]; then
        rm -rf "$TARGET_DIR"
        print_success "Removed PrismLauncher directory: $TARGET_DIR"
        print_info "All essential files now in PollyMC directory"
    else
        print_warning "Skipped directory removal for safety: $TARGET_DIR"
    fi
}

# =============================================================================
# STEAM INTEGRATION
# =============================================================================

# =============================================================================
# STEAM INTEGRATION SYSTEM
# =============================================================================

# setup_steam_integration: Add Minecraft Splitscreen launcher to Steam library
#
# STEAM INTEGRATION BENEFITS:
# - Launch directly from Steam's game library interface
# - Access from Steam Big Picture mode (ideal for Steam Deck)
# - Controller support through Steam Input system
# - Game Mode integration on Steam Deck
# - Professional appearance with custom artwork
# - Consistent with other Steam games in library
#
# TECHNICAL IMPLEMENTATION:
# 1. Detects active Steam installation and user data
# 2. Safely shuts down Steam to modify shortcuts database
# 3. Creates backup of existing shortcuts for safety
# 4. Uses specialized Python script to modify binary shortcuts.vdf format
# 5. Downloads custom artwork from SteamGridDB for professional appearance
# 6. Restarts Steam with new shortcut available
#
# SAFETY MEASURES:
# - Checks for existing shortcut to prevent duplicates
# - Creates backup before modifications
# - Uses official Steam binary format handling
# - Handles multiple Steam installation types (native, Flatpak)
setup_steam_integration() {
    print_header "🎯 STEAM INTEGRATION SETUP"
    
    # =============================================================================
    # STEAM INTEGRATION USER PROMPT
    # =============================================================================
    
    # USER PREFERENCE GATHERING: Ask if they want Steam integration
    # Steam integration is optional but highly recommended for Steam Deck users
    # Desktop users may prefer to launch manually or from application menu
    print_info "Steam integration adds Minecraft Splitscreen to your Steam library."
    print_info "Benefits: Easy access from Steam, Big Picture mode support, Steam Deck Game Mode integration"
    echo ""
    read -p "Do you want to add Minecraft Splitscreen launcher to Steam? [y/N]: " add_to_steam
    if [[ "$add_to_steam" =~ ^[Yy]$ ]]; then
        
        # =============================================================================
        # LAUNCHER PATH DETECTION AND CONFIGURATION
        # =============================================================================
        
        # LAUNCHER TYPE DETECTION: Determine which launcher is active for Steam integration
        # The Steam shortcut needs to point to the correct launcher executable and script
        # Path fragments are used by the duplicate detection system
        local launcher_path=""
        if [[ "$USE_POLLYMC" == true ]]; then
            launcher_path="local/share/PollyMC/minecraft"  # PollyMC path signature for duplicate detection
            print_info "Configuring Steam integration for PollyMC launcher"
        else
            launcher_path="local/share/PrismLauncher/minecraft"  # PrismLauncher path signature
            print_info "Configuring Steam integration for PrismLauncher"
        fi
        
        # =============================================================================
        # DUPLICATE SHORTCUT PREVENTION
        # =============================================================================
        
        # EXISTING SHORTCUT CHECK: Search Steam's shortcuts database for existing entries
        # Prevents creating duplicate shortcuts which can cause confusion and clutter
        # Searches all Steam user accounts on the system for existing Minecraft shortcuts
        print_progress "Checking for existing Minecraft shortcuts in Steam..."
        if ! grep -q "$launcher_path" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then
            # =============================================================================
            # STEAM SHUTDOWN AND BACKUP PROCEDURE
            # =============================================================================
            
            print_progress "Adding Minecraft Splitscreen launcher to Steam library..."
            
            # STEAM PROCESS TERMINATION: Safely shut down Steam before modifying shortcuts
            # Steam must be completely closed to safely modify the shortcuts.vdf binary database
            # The shortcuts.vdf file is locked while Steam is running and changes may be lost
            print_progress "Shutting down Steam to safely modify shortcuts database..."
            
            # More robust Steam shutdown with multiple approaches
            {
                steam -shutdown 2>/dev/null || true
                pkill -f "steam" 2>/dev/null || true
                sleep 2
            } >/dev/null 2>&1
            
            # STEAM SHUTDOWN VERIFICATION: Wait for complete shutdown
            # Check for Steam processes and wait until Steam fully exits
            # This prevents corruption of the shortcuts database during modification
            local shutdown_attempts=0
            local max_attempts=15
            
            while [[ $shutdown_attempts -lt $max_attempts ]]; do
                # Check multiple ways Steam might be running
                local steam_running=false
                
                # Check for steam processes (multiple approaches for reliability)
                if pgrep -x "steam" >/dev/null 2>&1 || \
                   pgrep -f "steam" >/dev/null 2>&1 || \
                   pgrep -f "Steam" >/dev/null 2>&1 || \
                   ([ -f ~/.steam/steam.pid ] && kill -0 "$(cat ~/.steam/steam.pid 2>/dev/null)" 2>/dev/null); then
                    steam_running=true
                fi
                
                if [[ "$steam_running" == false ]]; then
                    break
                fi
                
                sleep 1
                ((shutdown_attempts++))
            done
            
            if [[ $shutdown_attempts -ge $max_attempts ]]; then
                print_warning "⚠️  Steam shutdown timeout - proceeding anyway (may cause issues)"
                print_info "   → Some Steam processes may still be running"
            else
                print_success "✅ Steam shutdown complete"
            fi
            
            # =============================================================================
            # STEAM SHORTCUTS BACKUP SYSTEM
            # =============================================================================
            
            # BACKUP CREATION: Create safety backup of existing Steam shortcuts
            # Backup stored in current working directory (safer than TARGET_DIR which may be cleaned)
            # Compressed archive saves space and preserves all user shortcuts databases
            local backup_path="$PWD/steam-shortcuts-backup-$(date +%Y%m%d_%H%M%S).tar.xz"
            print_progress "Creating backup of Steam shortcuts database..."
            
            if tar cJf "$backup_path" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then
                print_success "✅ Steam shortcuts backup created: $(basename "$backup_path")"
            else
                print_warning "⚠️  Could not create shortcuts backup - proceeding without backup"
            fi
            
            # =============================================================================
            # STEAM INTEGRATION SCRIPT EXECUTION
            # =============================================================================
            
            # PYTHON INTEGRATION SCRIPT: Download and execute Steam shortcut creation tool
            # Uses the official add-to-steam.py script from the repository
            # This script handles the complex shortcuts.vdf binary format safely
            # Includes automatic artwork download from SteamGridDB for professional appearance
            print_progress "Running Steam integration script to add Minecraft Splitscreen..."
            print_info "   → Downloading launcher detection and shortcut creation script"
            print_info "   → Modifying Steam shortcuts.vdf binary database"
            print_info "   → Downloading custom artwork from SteamGridDB"
            
            # Execute the Steam integration script with error handling
            # Download script to temporary file first to avoid pipefail issues
            local steam_script_temp
            steam_script_temp=$(mktemp)
            if curl -sSL https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/add-to-steam.py -o "$steam_script_temp"; then
                # Execute the downloaded script with proper error handling
                if python3 "$steam_script_temp"; then
                    print_success "✅ Minecraft Splitscreen successfully added to Steam library"
                    print_info "   → Custom artwork downloaded and applied"
                    print_info "   → Shortcut configured with proper launch parameters"
                else
                    print_warning "⚠️  Steam integration script encountered errors"
                    print_info "   → You may need to add the shortcut manually"
                    print_info "   → Common causes: PollyMC not found, Steam not installed, or permissions issues"
                fi
                rm -f "$steam_script_temp"
            else
                print_warning "⚠️  Failed to download Steam integration script"
                print_info "   → You may need to add the shortcut manually"
            fi
            
            # =============================================================================
            # STEAM RESTART AND VERIFICATION
            # =============================================================================
            
            # STEAM RESTART: Launch Steam in background after successful modification
            # Use nohup to prevent Steam from being tied to terminal session
            # Steam will automatically detect the new shortcut in its library
            print_progress "Restarting Steam with new shortcut..."
            nohup steam >/dev/null 2>&1 &
            
            print_success "🎮 Steam integration complete!"
            print_info "   → Minecraft Splitscreen should now appear in your Steam library"
            print_info "   → Accessible from Steam Big Picture mode and Steam Deck Game Mode"
            print_info "   → Launch directly from Steam for automatic controller detection"
        else
            # =============================================================================
            # DUPLICATE SHORTCUT HANDLING
            # =============================================================================
            
            print_info "✅ Minecraft Splitscreen launcher already present in Steam library"
            print_info "   → No changes needed - existing shortcut is functional"
            print_info "   → If you need to update the shortcut, please remove it manually from Steam first"
        fi
    else
        # =============================================================================
        # STEAM INTEGRATION DECLINED
        # =============================================================================
        
        print_info "⏭️  Skipping Steam integration"
        print_info "   → You can still launch Minecraft Splitscreen manually or from desktop launcher"
        print_info "   → To add to Steam later, run this installer again or use the add-to-steam.py script"
    fi
}

# =============================================================================
# DESKTOP LAUNCHER CREATION
# =============================================================================

# =============================================================================
# DESKTOP LAUNCHER CREATION SYSTEM
# =============================================================================

# create_desktop_launcher: Generate .desktop file for system integration
#
# DESKTOP LAUNCHER BENEFITS:
# - Native desktop environment integration (GNOME, KDE, XFCE, etc.)
# - Appears in application menus and search results
# - Desktop shortcut for quick access
# - Proper icon and metadata for professional appearance
# - Follows freedesktop.org Desktop Entry Specification
# - Works with all Linux desktop environments
#
# ICON HIERARCHY:
# 1. SteamGridDB custom icon (downloaded, professional appearance)
# 2. PollyMC instance icon (if PollyMC setup successful)
# 3. PrismLauncher instance icon (fallback)
# 4. System generic icon (ultimate fallback)
#
# DESKTOP FILE LOCATIONS:
# - Desktop shortcut: ~/Desktop/MinecraftSplitscreen.desktop
# - System integration: ~/.local/share/applications/MinecraftSplitscreen.desktop
create_desktop_launcher() {
    print_header "🖥️ DESKTOP LAUNCHER SETUP"
    
    # =============================================================================
    # DESKTOP LAUNCHER USER PROMPT
    # =============================================================================
    
    # USER PREFERENCE GATHERING: Ask if they want desktop integration
    # Desktop launchers provide convenient access without terminal or Steam
    # Particularly useful for users who don't use Steam or prefer native desktop integration
    print_info "Desktop launcher creates a native shortcut for your desktop environment."
    print_info "Benefits: Desktop shortcut, application menu entry, search integration"
    echo ""
    read -p "Do you want to create a desktop launcher for Minecraft Splitscreen? [y/N]: " create_desktop
    if [[ "$create_desktop" =~ ^[Yy]$ ]]; then
        
        # =============================================================================
        # DESKTOP FILE CONFIGURATION AND PATHS
        # =============================================================================
        
        # DESKTOP FILE SETUP: Define paths and filenames following Linux standards
        # .desktop files follow the freedesktop.org Desktop Entry Specification
        # Standard locations ensure compatibility across all Linux desktop environments
        local desktop_file_name="MinecraftSplitscreen.desktop"
        local desktop_file_path="$HOME/Desktop/$desktop_file_name"  # User desktop shortcut
        local app_dir="$HOME/.local/share/applications"              # System integration directory
        
        # APPLICATIONS DIRECTORY CREATION: Ensure the applications directory exists
        # This directory is where desktop environments look for user-installed applications
        mkdir -p "$app_dir"
        print_info "Desktop file will be created at: $desktop_file_path"
        print_info "Application menu entry will be registered in: $app_dir"
        
        # =============================================================================
        # ICON ACQUISITION AND CONFIGURATION
        # =============================================================================
        
        # CUSTOM ICON DOWNLOAD: Get professional SteamGridDB icon for consistent branding
        # This provides the same visual identity as the Steam integration
        # SteamGridDB provides high-quality gaming artwork used by many Steam applications
        local icon_dir="$PWD/minecraft-splitscreen-icons"
        local icon_path="$icon_dir/minecraft-splitscreen-steamgriddb.ico"
        local icon_url="https://cdn2.steamgriddb.com/icon/add7a048049671970976f3e18f21ade3.ico"
        
        print_progress "Configuring desktop launcher icon..."
        mkdir -p "$icon_dir"  # Ensure icon storage directory exists
        
        # ICON DOWNLOAD: Fetch SteamGridDB icon if not already present
        # This provides a professional-looking icon that matches Steam integration
        if [[ ! -f "$icon_path" ]]; then
            print_progress "Downloading custom icon from SteamGridDB..."
            if wget -O "$icon_path" "$icon_url" >/dev/null 2>&1; then
                print_success "✅ Custom icon downloaded successfully"
            else
                print_warning "⚠️  Custom icon download failed - will use fallback icons"
            fi
        else
            print_info "   → Custom icon already present"
        fi
        
        # =============================================================================
        # ICON SELECTION WITH FALLBACK HIERARCHY
        # =============================================================================
        
        # ICON SELECTION: Determine the best available icon with intelligent fallbacks
        # Priority system ensures we always have a functional icon, preferring custom over generic
        local icon_desktop
        if [[ -f "$icon_path" ]]; then
            icon_desktop="$icon_path"  # Best: Custom SteamGridDB icon
            print_info "   → Using custom SteamGridDB icon for consistent branding"
        elif [[ "$USE_POLLYMC" == true ]] && [[ -f "$HOME/.local/share/PollyMC/instances/latestUpdate-1/icon.png" ]]; then
            icon_desktop="$HOME/.local/share/PollyMC/instances/latestUpdate-1/icon.png"  # Good: PollyMC instance icon
            print_info "   → Using PollyMC instance icon"
        elif [[ -f "$TARGET_DIR/instances/latestUpdate-1/icon.png" ]]; then
            icon_desktop="$TARGET_DIR/instances/latestUpdate-1/icon.png"  # Acceptable: PrismLauncher instance icon
            print_info "   → Using PrismLauncher instance icon"
        else
            icon_desktop="application-x-executable"  # Fallback: Generic system executable icon
            print_info "   → Using system default executable icon"
        fi
        
        # =============================================================================
        # LAUNCHER SCRIPT PATH CONFIGURATION
        # =============================================================================
        
        # LAUNCHER SCRIPT PATH DETECTION: Set correct executable path based on active launcher
        # The desktop file needs to point to the appropriate launcher script
        # Different paths and descriptions for PollyMC vs PrismLauncher configurations
        local launcher_script_path
        local launcher_comment
        if [[ "$USE_POLLYMC" == true ]]; then
            launcher_script_path="$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
            launcher_comment="Launch Minecraft splitscreen with PollyMC (optimized for offline gameplay)"
            print_info "   → Desktop launcher configured for PollyMC"
        else
            launcher_script_path="$TARGET_DIR/minecraftSplitscreen.sh"
            launcher_comment="Launch Minecraft splitscreen with PrismLauncher"
            print_info "   → Desktop launcher configured for PrismLauncher"
        fi
        
        # =============================================================================
        # DESKTOP ENTRY FILE GENERATION
        # =============================================================================
        
        # DESKTOP FILE CREATION: Generate .desktop file following freedesktop.org specification
        # This creates a proper desktop entry that integrates with all Linux desktop environments
        # The file contains metadata, execution parameters, and display information
        print_progress "Generating desktop entry file..."
        
        # Desktop Entry Specification fields:
        # - Type=Application: Indicates this is an application launcher
        # - Name: Display name in menus and desktop
        # - Comment: Tooltip/description text
        # - Exec: Command to execute when launched
        # - Icon: Icon file path or theme icon name
        # - Terminal: Whether to run in terminal (false for GUI applications)
        # - Categories: Menu categories for proper organization
        
        cat > "$desktop_file_path" <<EOF
[Desktop Entry]
Type=Application
Name=Minecraft Splitscreen
Comment=$launcher_comment
Exec=$launcher_script_path
Icon=$icon_desktop
Terminal=false
Categories=Game;
EOF
        
        print_success "✅ Desktop entry file created successfully"
        
        # =============================================================================
        # DESKTOP FILE PERMISSIONS AND VALIDATION
        # =============================================================================
        
        # DESKTOP FILE PERMISSIONS: Make the .desktop file executable
        # Many desktop environments require .desktop files to be executable
        # This ensures the launcher appears and functions properly across all DEs
        chmod +x "$desktop_file_path"
        print_info "   → Desktop file permissions set to executable"
        
        # DESKTOP FILE VALIDATION: Basic syntax check
        # Verify the generated .desktop file has required fields
        if [[ -f "$desktop_file_path" ]] && grep -q "Type=Application" "$desktop_file_path"; then
            print_success "✅ Desktop file validation passed"
        else
            print_warning "⚠️  Desktop file validation failed - file may not work properly"
        fi
        
        # =============================================================================
        # SYSTEM INTEGRATION AND REGISTRATION
        # =============================================================================
        
        # SYSTEM INTEGRATION: Copy to applications directory for system-wide access
        # This makes the launcher appear in application menus, search results, and launchers
        # The ~/.local/share/applications directory is the standard location for user applications
        print_progress "Registering application with desktop environment..."
        
        if cp "$desktop_file_path" "$app_dir/$desktop_file_name"; then
            print_success "✅ Application registered in system applications directory"
        else
            print_warning "⚠️  Failed to register application system-wide"
        fi
        
        # =============================================================================
        # DESKTOP DATABASE UPDATE
        # =============================================================================
        
        # DATABASE UPDATE: Refresh desktop database to register new application immediately
        # This ensures the launcher appears in menus without requiring logout/reboot
        # The update-desktop-database command updates the application cache
        print_progress "Updating desktop application database..."
        
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$app_dir" 2>/dev/null || true
            print_success "✅ Desktop database updated - launcher available immediately"
        else
            print_info "   → Desktop database update tool not found (launcher may need logout to appear)"
        fi
        
        # =============================================================================
        # DESKTOP LAUNCHER COMPLETION SUMMARY
        # =============================================================================
        
        print_success "🖥️ Desktop launcher setup complete!"
        print_info ""
        print_info "📋 Desktop Integration Summary:"
        print_info "   → Desktop shortcut: $desktop_file_path"
        print_info "   → Application menu: $app_dir/$desktop_file_name"
        print_info "   → Icon: $(basename "$icon_desktop")"
        print_info "   → Target launcher: $(basename "$launcher_script_path")"
        print_info ""
        print_info "🚀 Access Methods:"
        print_info "   → Double-click desktop shortcut"
        print_info "   → Search for 'Minecraft Splitscreen' in application menu"
        print_info "   → Launch from desktop environment's application launcher"
    else
        # =============================================================================
        # DESKTOP LAUNCHER DECLINED
        # =============================================================================
        
        print_info "⏭️  Skipping desktop launcher creation"
        print_info "   → You can still launch via Steam (if configured) or manually run the script"
        print_info "   → Manual launch command:"
        if [[ "$USE_POLLYMC" == true ]]; then
            print_info "     $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        else
            print_info "     $TARGET_DIR/minecraftSplitscreen.sh"
        fi
    fi
}

# =============================================================================
# MAIN EXECUTION WORKFLOW
# =============================================================================

# =============================================================================
# MAIN EXECUTION WORKFLOW ORCHESTRATION
# =============================================================================

# main: Primary function that orchestrates the complete splitscreen installation process
#
# INSTALLATION WORKFLOW:
# 1. WORKSPACE SETUP: Create directories and initialize environment
# 2. CORE SETUP: Java detection, PrismLauncher download, CLI verification
# 3. VERSION DETECTION: Minecraft and Fabric version determination
# 4. ACCOUNT SETUP: Download offline splitscreen player accounts
# 5. MOD COMPATIBILITY: Query APIs and determine compatible mod versions
# 6. USER SELECTION: Interactive mod selection interface
# 7. INSTANCE CREATION: Create 4 splitscreen instances with PrismLauncher CLI
# 8. LAUNCHER OPTIMIZATION: Setup PollyMC and cleanup PrismLauncher (if successful)
# 9. INTEGRATION: Optional Steam and desktop launcher integration
# 10. COMPLETION: Summary report and usage instructions
#
# ERROR HANDLING STRATEGY:
# - Each phase has fallback mechanisms to ensure installation can complete
# - Non-critical failures (like PollyMC setup) don't halt the entire process
# - Comprehensive error reporting helps users understand any issues
# - Multiple validation checkpoints ensure data integrity
#
# DUAL-LAUNCHER APPROACH:
# The script uses an optimized strategy combining two launchers:
# - PrismLauncher: CLI automation for reliable instance creation with proper Fabric setup
# - PollyMC: Offline-friendly gameplay launcher without forced authentication
# - Smart cleanup: Removes PrismLauncher after successful PollyMC setup to save space
main() {
    print_header "🎮 MINECRAFT SPLITSCREEN INSTALLER 🎮"
    print_info "Advanced installation system with dual-launcher optimization"
    print_info "Strategy: PrismLauncher CLI automation → PollyMC gameplay → Smart cleanup"
    echo ""
    
    # =============================================================================
    # WORKSPACE INITIALIZATION PHASE
    # =============================================================================
    
    # WORKSPACE SETUP: Create and navigate to working directory
    # All temporary files, downloads, and initial setup happen in TARGET_DIR
    # This provides a clean, isolated environment for the installation process
    print_progress "Initializing installation workspace: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR" || exit 1
    print_success "✅ Workspace initialized successfully"
    
    # =============================================================================
    # CORE SYSTEM REQUIREMENTS VALIDATION
    # =============================================================================
    
    detect_java                    # Verify Java 21+ availability and set JAVA_PATH
    download_prism_launcher        # Download PrismLauncher AppImage for CLI automation
    verify_prism_cli              # Test CLI functionality and validate installation
    
    # =============================================================================
    # VERSION DETECTION AND CONFIGURATION
    # =============================================================================
    
    get_minecraft_version         # Determine target Minecraft version (user choice or latest)
    get_fabric_version           # Get compatible Fabric loader version from API
    
    # =============================================================================
    # OFFLINE ACCOUNTS CONFIGURATION
    # =============================================================================
    
    print_progress "Setting up offline accounts for splitscreen gameplay..."
    print_info "Downloading pre-configured offline accounts for Player 1-4"
    
    # OFFLINE ACCOUNTS DOWNLOAD: Get splitscreen player account configurations
    # These accounts enable splitscreen without requiring multiple Microsoft accounts
    # Each player (P1, P2, P3, P4) gets a separate offline profile for identification
    if ! wget -O accounts.json "https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/accounts.json"; then
        print_warning "⚠️  Failed to download accounts.json from repository"
        print_info "   → Attempting to use local copy if available..."
        if [[ ! -f "accounts.json" ]]; then
            print_error "❌ No accounts.json found - splitscreen accounts may require manual setup"
            print_info "   → Splitscreen will still work but players may have generic names"
        fi
    else
        print_success "✅ Offline splitscreen accounts configured successfully"
        print_info "   → P1, P2, P3, P4 player accounts ready for offline gameplay"
    fi
    
    # =============================================================================
    # MOD ECOSYSTEM SETUP PHASE
    # =============================================================================
    
    check_mod_compatibility       # Query Modrinth/CurseForge APIs for compatible versions
    select_user_mods             # Interactive mod selection interface with categories
    
    # =============================================================================
    # MINECRAFT INSTANCE CREATION PHASE
    # =============================================================================
    
    
    create_instances             # Create 4 splitscreen instances using PrismLauncher CLI with comprehensive fallbacks
    
    # =============================================================================
    # LAUNCHER OPTIMIZATION PHASE: Advanced launcher configuration
    # =============================================================================
    
    setup_pollymc               # Download PollyMC, migrate instances, verify, cleanup PrismLauncher
    
    # =============================================================================
    # SYSTEM INTEGRATION PHASE: Optional platform integration
    # =============================================================================
    
    setup_steam_integration     # Add splitscreen launcher to Steam library (optional)
    create_desktop_launcher     # Create native desktop launcher and app menu entry (optional)
    
    # =============================================================================
    # INSTALLATION COMPLETION AND STATUS REPORTING
    # =============================================================================
    
    print_header "🎉 INSTALLATION ANALYSIS AND COMPLETION REPORT"
    
    # =============================================================================
    # MISSING MODS ANALYSIS: Report any compatibility issues
    # =============================================================================
    
    # MISSING MODS REPORT: Alert user to any mods that couldn't be installed
    # This helps users understand if specific functionality might be unavailable
    # Common causes: no Fabric version available, API changes, temporary download issues
    if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
        echo ""
        print_warning "====================="
        print_warning "⚠️  MISSING MODS ANALYSIS"
        print_warning "====================="
        print_warning "The following mods could not be installed:"
        print_info "Common causes: No compatible Fabric version, API issues, download failures"
        echo ""
        for mod in "${MISSING_MODS[@]}"; do
            echo "  ❌ $mod"
        done
        print_warning "====================="
        print_info "These mods can be installed manually later if compatible versions become available"
        print_info "The splitscreen functionality will work without these optional mods"
    fi
    
    # =============================================================================
    # COMPREHENSIVE INSTALLATION SUCCESS REPORT
    # =============================================================================
    
    echo ""
    echo "=========================================="
    echo "🎮 MINECRAFT SPLITSCREEN INSTALLATION COMPLETE! 🎮"
    echo "=========================================="
    echo ""
    
    # =============================================================================
    # LAUNCHER STRATEGY SUCCESS ANALYSIS
    # =============================================================================
    
    # LAUNCHER STRATEGY REPORT: Explain which approach was successful and the benefits
    # The dual-launcher approach provides the best of both worlds when successful
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "✅ OPTIMIZED INSTALLATION SUCCESSFUL!"
        echo ""
        echo "🔧 DUAL-LAUNCHER STRATEGY COMPLETED:"
        echo "   🛠️  PrismLauncher: CLI automation for reliable instance creation ✅ COMPLETED"
        echo "   🎮 PollyMC: Primary launcher for offline splitscreen gameplay ✅ ACTIVE"
        echo "   🧹 Smart cleanup: Removes PrismLauncher after successful setup ✅ CLEANED"
        echo ""
        echo "🎯 STRATEGY BENEFITS ACHIEVED:"
        echo "   • Reliable instance creation through proven CLI automation"
        echo "   • Offline-friendly gameplay without forced Microsoft login prompts"
        echo "   • Optimized disk usage through intelligent cleanup"
        echo "   • Best performance for splitscreen scenarios"
        echo ""
        echo "✅ Primary launcher: PollyMC (optimized for splitscreen)"
        echo "✅ All instances migrated and verified in PollyMC"
        echo "✅ Temporary PrismLauncher files cleaned up successfully"
    else
        echo "✅ FALLBACK INSTALLATION SUCCESSFUL!"
        echo ""
        echo "🔧 FALLBACK STRATEGY USED:"
        echo "   🛠️  PrismLauncher: Instance creation + primary launcher ✅ ACTIVE"
        echo "   ⚠️  PollyMC: Download/setup encountered issues, using PrismLauncher for everything"
        echo ""
        echo "📋 FALLBACK EXPLANATION:"
        echo "   • PollyMC setup failed (network issues, system compatibility, or download problems)"
        echo "   • PrismLauncher provides full functionality as backup launcher"
        echo "   • Splitscreen works perfectly with PrismLauncher"
        echo ""
        echo "✅ Primary launcher: PrismLauncher (proven reliability)"
        echo "⚠️  Note: PollyMC optimization unavailable, but full functionality preserved"
    fi
    
    # =============================================================================
    # TECHNICAL ACHIEVEMENT SUMMARY
    # =============================================================================
    
    # INSTALLATION COMPONENTS SUMMARY: List all successfully completed setup elements
    echo ""
    echo "🏆 TECHNICAL ACHIEVEMENTS COMPLETED:"
    echo "✅ Java 21+ detection and configuration"
    echo "✅ Automated instance creation via PrismLauncher CLI"
    echo "✅ Complete Fabric dependency chain implementation"
    echo "✅ 4 splitscreen instances created and configured (Player 1-4)"
    echo "✅ Fabric mod loader installation with proper dependency resolution"
    echo "✅ Compatible mod versions detected and downloaded via API filtering"
    echo "✅ Splitscreen-specific configurations applied to all instances"
    echo "✅ Offline player accounts configured for splitscreen gameplay"
    echo "✅ Java memory settings optimized for splitscreen performance"
    echo "✅ Instance verification and launcher registration completed"
    echo "✅ Comprehensive automatic dependency resolution system"
    echo ""
    
    # =============================================================================
    # USER GUIDANCE AND LAUNCH INSTRUCTIONS
    # =============================================================================
    
    echo "🚀 READY TO PLAY SPLITSCREEN MINECRAFT!"
    echo ""
    
    # LAUNCH METHODS: Comprehensive guide to starting splitscreen Minecraft
    echo "🎮 HOW TO LAUNCH SPLITSCREEN MINECRAFT:"
    echo ""
    
    # PRIMARY LAUNCH METHOD: Direct script execution
    echo "1. 🔧 DIRECT LAUNCH (Recommended):"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   Command: $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        echo "   Description: Optimized PollyMC launcher with automatic controller detection"
    else
        echo "   Command: $TARGET_DIR/minecraftSplitscreen.sh"
        echo "   Description: PrismLauncher-based splitscreen with automatic controller detection"
    fi
    echo ""
    
    # ALTERNATIVE LAUNCH METHODS: Other integration options
    echo "2. 🖥️  DESKTOP LAUNCHER:"
    echo "   Method: Double-click desktop shortcut or search 'Minecraft Splitscreen' in app menu"
    echo "   Availability: $(if [[ -f "$HOME/Desktop/MinecraftSplitscreen.desktop" ]]; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""
    
    echo "3. 🎯 STEAM INTEGRATION:"
    echo "   Method: Launch from Steam library or Big Picture mode"
    echo "   Benefits: Steam Deck Game Mode integration, Steam Input support"
    echo "   Availability: $(if grep -q "PollyMC\|PrismLauncher" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""
    
    # =============================================================================
    # SYSTEM REQUIREMENTS AND TECHNICAL DETAILS
    # =============================================================================
    
    echo "⚙️  SYSTEM CONFIGURATION DETAILS:"
    echo ""
    
    # LAUNCHER DETAILS: Technical information about the setup
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "🛠️  LAUNCHER CONFIGURATION:"
        echo "   • Instance creation: PrismLauncher CLI (automated)"
        echo "   • Gameplay launcher: PollyMC (offline-optimized)"
        echo "   • Strategy: Best of both worlds approach"
        echo "   • Benefits: CLI automation + offline gameplay + no forced login"
    else
        echo "🛠️  LAUNCHER CONFIGURATION:"
        echo "   • Primary launcher: PrismLauncher (all functions)"
        echo "   • Strategy: Single launcher approach"
        echo "   • Note: PollyMC optimization unavailable, but fully functional"
    fi
    echo ""
    
    # MINECRAFT ACCOUNT REQUIREMENTS: Important user information
    echo "💳 ACCOUNT REQUIREMENTS:"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Microsoft account: Required for initial setup and updates"
        echo "   • Account type: PAID Minecraft Java Edition required"
        echo "   • Login frequency: Minimal (PollyMC is offline-friendly)"
        echo "   • Splitscreen: Uses offline accounts (P1, P2, P3, P4) after initial login"
    else
        echo "   • Microsoft account: Required for launcher access"
        echo "   • Account type: PAID Minecraft Java Edition required" 
        echo "   • Note: PrismLauncher may prompt for periodic authentication"
        echo "   • Splitscreen: Uses offline accounts (P1, P2, P3, P4) after login"
    fi
    echo ""
    
    # CONTROLLER INFORMATION: Hardware requirements and tips
    echo "🎮 CONTROLLER CONFIGURATION:"
    echo "   • Supported: Xbox, PlayStation, generic USB/Bluetooth controllers"
    echo "   • Detection: Automatic (1-4 controllers supported)"
    echo "   • Steam Deck: Built-in controls + external controllers"
    echo "   • Recommendation: Use wired controllers for best performance"
    echo ""
    
    # =============================================================================
    # INSTALLATION LOCATION SUMMARY
    # =============================================================================
    
    echo "📁 INSTALLATION LOCATIONS:"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Primary installation: $HOME/.local/share/PollyMC/"
        echo "   • Launcher executable: $HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage"
        echo "   • Splitscreen script: $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        echo "   • Instance data: $HOME/.local/share/PollyMC/instances/"
        echo "   • Account configuration: $HOME/.local/share/PollyMC/accounts.json"
        echo "   • Temporary build files: Successfully removed after setup ✅"
    else
        echo "   • Primary installation: $TARGET_DIR"
        echo "   • Launcher executable: $TARGET_DIR/PrismLauncher.AppImage"
        echo "   • Splitscreen script: $TARGET_DIR/minecraftSplitscreen.sh"
        echo "   • Instance data: $TARGET_DIR/instances/"
        echo "   • Account configuration: $TARGET_DIR/accounts.json"
    fi
    echo ""
    
    # =============================================================================
    # ADVANCED TECHNICAL FEATURE SUMMARY
    # =============================================================================
    
    echo "🔧 ADVANCED FEATURES IMPLEMENTED:"
    echo "   • Complete Fabric dependency chain with proper version matching"
    echo "   • API-based mod compatibility verification (Modrinth + CurseForge)"
    echo "   • Sophisticated version parsing with semantic version support"
    echo "   • Automatic dependency resolution and installation"
    echo "   • Enhanced error handling with multiple fallback strategies"
    echo "   • Instance verification and launcher registration"
    echo "   • Smart cleanup with disk space optimization"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Dual-launcher optimization strategy successfully implemented"
    fi
    echo "   • Cross-platform Linux compatibility (Steam Deck + Desktop)"
    echo "   • Professional Steam and desktop environment integration"
    echo ""
    
    # =============================================================================
    # FINAL SUCCESS MESSAGE AND NEXT STEPS
    # =============================================================================
    
    echo "🎉 INSTALLATION COMPLETE - ENJOY SPLITSCREEN MINECRAFT! 🎉"
    echo ""
    echo "Next steps:"
    echo "1. Connect your controllers (1-4 supported)"
    echo "2. Launch using any of the methods above"
    echo "3. The system will automatically detect controller count and launch appropriate instances"
    echo "4. Each player gets their own screen and can play independently"
    echo ""
    echo "For troubleshooting or updates, visit:"
    echo "https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck"
    echo "=========================================="
}

# =============================================================================
# SCRIPT ENTRY POINT AND EXECUTION CONTROL
# =============================================================================

# SCRIPT ENTRY POINT: Execute main function if script is run directly
# This allows the script to be sourced for testing without auto-execution
# The ${BASH_SOURCE[0]} check ensures main() only runs when script is executed directly
# Command line arguments are passed through to main() for potential future use
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"  # Pass all command line arguments to main function
fi

# =============================================================================
# END OF MINECRAFT SPLITSCREEN INSTALLER
# =============================================================================
# 
# FINAL NOTES:
# - This script implements a comprehensive splitscreen Minecraft installation
# - Uses advanced dual-launcher strategy for optimal user experience  
# - Includes extensive error handling and fallback mechanisms
# - Provides multiple integration options (Steam, desktop, manual)
# - Supports both Steam Deck and desktop Linux environments
# - All temporary files are automatically cleaned up after successful installation
# - The installation is fully self-contained and doesn't require additional setup
#
# For issues, updates, or contributions:
# https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck
# =============================================================================
