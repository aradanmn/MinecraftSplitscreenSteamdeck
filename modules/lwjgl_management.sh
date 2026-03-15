#!/bin/bash
# =============================================================================
# @file        lwjgl_management.sh
# @version     3.0.1
# @date        2026-03-15
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Dynamic LWJGL (Lightweight Java Game Library) version detection for Minecraft.
#   LWJGL provides the native bindings for OpenGL, OpenAL, and input handling
#   that Minecraft requires. Different Minecraft versions need specific LWJGL versions.
#
#   Detection strategy:
#   1. Query Fabric Meta API for exact LWJGL version
#   2. Fall back to hardcoded version mappings
#   3. Default to 3.3.3 for unknown versions
#
# @dependencies
#   - utilities.sh (for print_progress, print_success, print_warning)
#   - curl or wget (for API requests)
#   - jq (for JSON parsing, optional)
#
# @global_inputs
#   - MC_VERSION: Target Minecraft version
#
# @global_outputs
#   - LWJGL_VERSION: Detected LWJGL version string (e.g., "3.3.3")
#
# @exports
#   Functions:
#     - get_lwjgl_version        : Main detection function
#     - get_lwjgl_version_by_mapping : Fallback mapping lookup
#     - validate_lwjgl_version   : Version format validation
#
# @changelog
#   2.0.1 (2026-01-31) - Fix: Replace hardcoded /tmp with mktemp
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# -----------------------------------------------------------------------------
# Module Variables
# -----------------------------------------------------------------------------

# @global LWJGL_VERSION
# @description Stores the detected LWJGL version for the target Minecraft version
LWJGL_VERSION=""

# =============================================================================
# LWJGL VERSION DETECTION
# =============================================================================

# @function    get_lwjgl_version
# @description Detect the appropriate LWJGL version for the current Minecraft version.
#              First attempts to query Fabric Meta API, then falls back to
#              hardcoded version mappings.
# @global      MC_VERSION - (input) Target Minecraft version
# @global      LWJGL_VERSION - (output) Set to detected version string
# @return      0 always (uses fallback on failure)
# @example
#   MC_VERSION="1.21.3"
#   get_lwjgl_version
#   echo "LWJGL: $LWJGL_VERSION"  # Outputs: "LWJGL: 3.3.3"
get_lwjgl_version() {
    print_progress "Detecting LWJGL version for Minecraft $MC_VERSION..."

    # First try to get LWJGL version from Fabric Meta API
    local fabric_game_url="https://meta.fabricmc.net/v2/versions/game"
    local temp_file
    temp_file=$(mktemp)

    if command -v wget >/dev/null 2>&1; then
        if wget -q -O "$temp_file" "$fabric_game_url" 2>/dev/null; then
            if command -v jq >/dev/null 2>&1 && [[ -s "$temp_file" ]]; then
                # Try to find LWJGL version for our Minecraft version
                LWJGL_VERSION=$(jq -r --arg mc_ver "$MC_VERSION" '
                    .[] | select(.version == $mc_ver) | .lwjgl // empty
                ' "$temp_file" 2>/dev/null)
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        if curl -s -o "$temp_file" "$fabric_game_url" 2>/dev/null; then
            if command -v jq >/dev/null 2>&1 && [[ -s "$temp_file" ]]; then
                # Try to find LWJGL version for our Minecraft version
                LWJGL_VERSION=$(jq -r --arg mc_ver "$MC_VERSION" '
                    .[] | select(.version == $mc_ver) | .lwjgl // empty
                ' "$temp_file" 2>/dev/null)
            fi
        fi
    fi

    # Clean up temp file
    [[ -f "$temp_file" ]] && rm -f "$temp_file"

    # If API lookup failed, use version mapping logic
    if [[ -z "$LWJGL_VERSION" || "$LWJGL_VERSION" == "null" ]]; then
        LWJGL_VERSION=$(get_lwjgl_version_for_mc "$MC_VERSION")
    fi

    # Final fallback
    if [[ -z "$LWJGL_VERSION" ]]; then
        print_warning "Could not detect LWJGL version, using fallback"
        LWJGL_VERSION="3.3.3"
    fi

    print_success "Using LWJGL version: $LWJGL_VERSION"
}
