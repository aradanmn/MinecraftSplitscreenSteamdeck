#!/bin/bash
# =============================================================================
# LWJGL VERSION DETECTION
# =============================================================================
# Dynamic LWJGL version detection based on Minecraft version

# Global variable to store detected LWJGL version
LWJGL_VERSION=""

# get_lwjgl_version: Detect appropriate LWJGL version for Minecraft version
# Uses Fabric Meta API and version mapping logic
get_lwjgl_version() {
    print_progress "Detecting LWJGL version for Minecraft $MC_VERSION..."
    
    # First try to get LWJGL version from Fabric Meta API
    local fabric_game_url="https://meta.fabricmc.net/v2/versions/game"
    local temp_file="/tmp/fabric_versions_$$.json"
    
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
        LWJGL_VERSION=$(get_lwjgl_version_by_mapping "$MC_VERSION")
    fi
    
    # Final fallback
    if [[ -z "$LWJGL_VERSION" ]]; then
        print_warning "Could not detect LWJGL version, using fallback"
        LWJGL_VERSION="3.3.3"
    fi
    
    print_success "Using LWJGL version: $LWJGL_VERSION"
}

# get_lwjgl_version_by_mapping: Map Minecraft version to LWJGL version
# Parameters:
#   $1 - Minecraft version (e.g., "1.21.3")
# Returns: Appropriate LWJGL version
get_lwjgl_version_by_mapping() {
    local mc_version="$1"
    
    # LWJGL version mapping based on Minecraft releases
    # Source: https://minecraft.wiki/w/Tutorials/Update_LWJGL
    if [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
        echo "3.3.3"  # MC 1.21+ uses LWJGL 3.3.3
    elif [[ "$mc_version" =~ ^1\.(19|20)(\.|$) ]]; then
        echo "3.3.1"  # MC 1.19-1.20 uses LWJGL 3.3.1
    elif [[ "$mc_version" =~ ^1\.18(\.|$) ]]; then
        echo "3.2.2"  # MC 1.18 uses LWJGL 3.2.2
    elif [[ "$mc_version" =~ ^1\.(16|17)(\.|$) ]]; then
        echo "3.2.1"  # MC 1.16-1.17 uses LWJGL 3.2.1
    elif [[ "$mc_version" =~ ^1\.(14|15)(\.|$) ]]; then
        echo "3.1.6"  # MC 1.14-1.15 uses LWJGL 3.1.6
    elif [[ "$mc_version" =~ ^1\.13(\.|$) ]]; then
        echo "3.1.2"  # MC 1.13 uses LWJGL 3.1.2
    else
        echo "3.3.3"  # Default to latest for unknown versions
    fi
}

# validate_lwjgl_version: Ensure LWJGL version is valid
# Parameters:
#   $1 - LWJGL version to validate
# Returns: 0 if valid, 1 if invalid
validate_lwjgl_version() {
    local version="$1"
    
    # Check if version matches expected format (e.g., "3.3.3")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}
