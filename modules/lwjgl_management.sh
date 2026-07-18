#!/bin/bash
# =============================================================================
# LWJGL MANAGEMENT MODULE
# =============================================================================
# Resolves the LWJGL version required for a given Minecraft version: tries
# the Fabric Meta API first, then falls back to a static version mapping.
#
# Public API:
#   get_lwjgl_version()                — sets LWJGL_VERSION; stdout: progress
#                                         text only, no return value
#   get_lwjgl_version_by_mapping(mc)   — stdout: LWJGL version string
#   validate_lwjgl_version(ver)        — exit 0 if "N.N.N"-shaped, else 1
#
# Globals PROVIDED (set here, read by installer/instance_creation.sh):
#   LWJGL_VERSION       — resolved LWJGL version, set by get_lwjgl_version
#
# Globals CONSUMED (set elsewhere, read here):
#   MC_VERSION                — target Minecraft version (installer globals)
#   FABRIC_META_BASE          — Fabric Meta API base URL (installer globals)
#
# Inputs:  Fabric Meta API (FABRIC_META_BASE/versions/game)
# Outputs: print_* progress/status to stdout/stderr; LWJGL_VERSION global
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.2 2026-07-15  #51 D14: fetch_url replaces the curl/wget branch
#   v1.1 2026-07-10  #45 PR3: FABRIC_META_BASE API-base constant adopted
#   v1.0 2026-06-21  LWJGL 3.4.1 mapping for MC 26.x.x / 1.21+ (Sodium)
#   v0.1 2025-06-27  Initial extraction from monolith
# =============================================================================

# Global variable to store detected LWJGL version (PROVIDED — see header).
LWJGL_VERSION=""

# get_lwjgl_version: Detect the appropriate LWJGL version for MC_VERSION.
# Tries the Fabric Meta API first, then falls back to
# get_lwjgl_version_by_mapping, then a hardcoded default.
# Inputs:
#   Globals: MC_VERSION (read), FABRIC_META_BASE (read)
# Outputs:
#   side effect — sets global LWJGL_VERSION (this IS the return channel;
#                 not called via command substitution, so its print_*
#                 progress text on stdout is never captured)
get_lwjgl_version() {
    print_progress "Detecting LWJGL version for Minecraft $MC_VERSION..."
    
    # First try to get LWJGL version from Fabric Meta API
    local fabric_game_url="${FABRIC_META_BASE}/versions/game"
    local temp_file="/tmp/fabric_versions_$$.json"
    
    # Fix #51 (D14): fetch_url replaces the duplicated wget/curl branches.
    if fetch_url "$fabric_game_url" "$temp_file" 2>/dev/null; then
        if command -v jq >/dev/null 2>&1 && [[ -s "$temp_file" ]]; then
            # Try to find LWJGL version for our Minecraft version
            LWJGL_VERSION=$(jq -r --arg mc_ver "$MC_VERSION" '
                .[] | select(.version == $mc_ver) | .lwjgl // empty
            ' "$temp_file" 2>/dev/null)
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
        LWJGL_VERSION="3.4.1"
    fi
    
    print_success "Using LWJGL version: $LWJGL_VERSION"
}

# get_lwjgl_version_by_mapping: Map a Minecraft version to its LWJGL version
# via a static, ordered range table (used when the Fabric Meta API lookup in
# get_lwjgl_version fails or has no entry for this MC version).
# Inputs:
#   $1 — mc_version (e.g., "1.21.3", or "26.1" 2026 yearly scheme)
# Outputs:
#   stdout — LWJGL version string (e.g., "3.4.1")
get_lwjgl_version_by_mapping() {
    local mc_version="$1"
    
    # LWJGL version mapping based on Minecraft releases
    # Source: https://minecraft.wiki/w/Tutorials/Update_LWJGL
    # MC 26.x.x is the new (2026) versioning scheme; 3.4.1 required by Sodium.
    if [[ "$mc_version" =~ ^[2-9][0-9]+\. ]]; then
        echo "3.4.1"  # MC 26.x.x+ (new 2026 versioning) uses LWJGL 3.4.1
    elif [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
        echo "3.4.1"  # MC 1.21+ uses LWJGL 3.4.1 (Sodium requirement)
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

# validate_lwjgl_version: Check that a string is a valid "N.N.N" LWJGL version.
# Inputs:
#   $1 — version string to validate
# Outputs:
#   return — 0 if valid, 1 if invalid
validate_lwjgl_version() {
    local version="$1"
    
    # Check if version matches expected format (e.g., "3.3.3")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}
