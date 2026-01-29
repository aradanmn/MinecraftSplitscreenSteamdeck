#!/bin/bash
# =============================================================================
# @file        version_management.sh
# @version     2.0.0
# @date        2026-01-25
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Minecraft and Fabric version selection and detection functions.
#   Implements intelligent version selection based on required mod compatibility,
#   querying APIs to verify that both essential splitscreen mods (Controllable
#   and Splitscreen Support) are available for each version.
#
#   Key features:
#   - Dynamic version compatibility checking via Modrinth/CurseForge APIs
#   - Multi-stage version matching (exact → major.minor → wildcard)
#   - Interactive version selection with fallback recommendations
#   - Fabric loader version detection from official API
#
# @dependencies
#   - utilities.sh (for print_progress, print_success, print_warning, print_error, print_info, print_header)
#   - curl (for API requests)
#   - jq (for JSON parsing)
#   - openssl (for CurseForge API token decryption)
#
# @global_outputs
#   - MC_VERSION: Selected Minecraft version
#   - FABRIC_VERSION: Detected Fabric loader version
#
# @exports
#   Functions:
#     - get_supported_minecraft_versions : Get list of compatible MC versions
#     - check_mod_version_compatibility  : Check single mod/version compatibility
#     - fallback_dependencies            : Hardcoded dependency fallbacks
#     - get_minecraft_version            : Interactive version selection
#     - get_fabric_version               : Fetch latest Fabric loader version
#
# @changelog
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# =============================================================================
# VERSION COMPATIBILITY CHECKING
# =============================================================================

# @function    get_supported_minecraft_versions
# @description Check what Minecraft versions support both required splitscreen mods
#              (Controllable and Splitscreen Support). Queries APIs to find compatible versions.
# @stdout      Array of supported Minecraft versions in descending order (newest first)
# @stderr      Progress and status messages
# @return      0 if versions found, 1 if none found or API error
get_supported_minecraft_versions() {
    print_progress "Checking supported Minecraft versions for essential splitscreen mods..." >&2

    local -a supported_versions=()
    local -a all_versions=()

    # Get all Minecraft versions from Mojang API
    local mojang_versions
    mojang_versions=$(curl -s "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" 2>/dev/null | jq -r '.versions[] | select(.type=="release") | .id' 2>/dev/null)

    if [[ -z "$mojang_versions" ]]; then
        print_error "Could not fetch Minecraft versions from Mojang API" >&2
        print_error "Please check your internet connection and try again" >&2
        return 1
    else
        # Convert to array and limit to recent versions (last 15 releases for testing)
        readarray -t all_versions <<< "$mojang_versions"
        all_versions=("${all_versions[@]:0:15}")
    fi

    print_info "Checking compatibility for required splitscreen mods..." >&2

    # Check each Minecraft version for compatibility with BOTH required mods
    # This is the ONLY filter - actual API testing, no hardcoded exclusions
    for mc_version in "${all_versions[@]}"; do
        print_progress "  Testing $mc_version..." >&2

        local controllable_compatible=false
        local splitscreen_compatible=false

        # Check Controllable (CurseForge mod 317269)
        if check_mod_version_compatibility "317269" "curseforge" "$mc_version"; then
            controllable_compatible=true
        fi

        # Check Splitscreen Support (Modrinth mod yJgqfSDR)
        if check_mod_version_compatibility "yJgqfSDR" "modrinth" "$mc_version"; then
            splitscreen_compatible=true
        fi

        # Only include versions where BOTH essential mods are available
        if [[ "$controllable_compatible" == true && "$splitscreen_compatible" == true ]]; then
            supported_versions+=("$mc_version")
            print_success "    ✅ $mc_version - Both mods compatible" >&2
        else
            print_info "    ❌ $mc_version - Missing essential mod support" >&2
        fi
    done

    if [[ ${#supported_versions[@]} -eq 0 ]]; then
        print_error "No Minecraft versions found with both required mods available!" >&2
        print_error "This may be due to API issues. Please try again later or check your internet connection." >&2
        return 1
    fi

    # Return the supported versions array (to stdout only)
    printf '%s\n' "${supported_versions[@]}"
}

# @function    check_mod_version_compatibility
# @description Check if a specific mod supports a specific Minecraft version.
#              Lightweight version check that doesn't add mods to arrays.
#              Uses multi-stage version matching for flexible compatibility.
# @param       $1 - mod_id: Mod ID (Modrinth project ID or CurseForge project ID)
# @param       $2 - platform: "modrinth" or "curseforge"
# @param       $3 - mc_version: Minecraft version to check (e.g., "1.21.3")
# @return      0 if compatible, 1 if not compatible or API error
check_mod_version_compatibility() {
    local mod_id="$1"
    local platform="$2"
    local mc_version="$3"

    if [[ "$platform" == "modrinth" ]]; then
        # Check Modrinth mod for version compatibility using same logic as check_modrinth_mod
        local api_url="https://api.modrinth.com/v2/project/$mod_id/version"
        local tmp_body
        tmp_body=$(mktemp)
        if [[ -z "$tmp_body" ]]; then
            return 1
        fi

        # Fetch version data from Modrinth API
        local http_code
        http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" "$api_url")
        local version_json
        version_json=$(cat "$tmp_body")
        rm "$tmp_body"

        # Validate API response
        if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
            return 1
        fi

        # Use the same multi-stage version matching logic as check_modrinth_mod
        local file_url=""

        # STAGE 1: Try exact version match with Fabric loader requirement
        file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_version" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)

        # STAGE 2: Strict fallback to major.minor version if exact match failed
        if [[ -z "$file_url" || "$file_url" == "null" ]]; then
            local mc_major_minor
            mc_major_minor=$(echo "$mc_version" | grep -oE '^[0-9]+\.[0-9]+')
            local requested_patch
            requested_patch=$(echo "$mc_version" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')

            # Get all available game versions for this mod to validate fallback logic
            local all_game_versions
            all_game_versions=$(printf "%s" "$version_json" | jq -r '.[] | select(.loaders[] == "fabric") | .game_versions[]' 2>/dev/null | sort -u)

            # Check if any patch versions or standalone major.minor exist for this series
            local has_patch_versions=false
            local has_standalone_major_minor=false
            local highest_patch_version=0

            while IFS= read -r version; do
                if [[ "$version" =~ ^${mc_major_minor//./\.}\.([0-9]+)$ ]]; then
                    has_patch_versions=true
                    local patch_num="${BASH_REMATCH[1]}"
                    if [[ $patch_num -gt $highest_patch_version ]]; then
                        highest_patch_version=$patch_num
                    fi
                elif [[ "$version" == "$mc_major_minor" ]]; then
                    has_standalone_major_minor=true
                fi
            done <<< "$all_game_versions"

            # Apply strict fallback rules:
            # 1. If we have patch versions AND the requested patch > highest available patch, block fallback
            # 2. Only allow fallback to major.minor if no patch versions exist OR standalone major.minor exists
            local allow_fallback=true

            if [[ $has_patch_versions == true && -n "$requested_patch" ]]; then
                if [[ $requested_patch -gt $highest_patch_version ]]; then
                    allow_fallback=false
                fi
            fi

            # Only proceed with fallback if allowed
            if [[ $allow_fallback == true ]]; then
                # Try exact major.minor (e.g., "1.21")
                file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)

                # Try wildcard version format (e.g., "1.21.x")
                if [[ -z "$file_url" || "$file_url" == "null" ]]; then
                    local mc_major_minor_x="$mc_major_minor.x"
                    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
                fi

                # Try zero-padded version format (e.g., "1.21.0")
                if [[ -z "$file_url" || "$file_url" == "null" ]]; then
                    local mc_major_minor_0="$mc_major_minor.0"
                    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
                fi
            fi
        fi

        # Return success if we found a compatible version
        if [[ -n "$file_url" && "$file_url" != "null" ]]; then
            return 0  # Compatible
        fi

    elif [[ "$platform" == "curseforge" ]]; then
        # Check CurseForge mod for version compatibility using same logic as check_curseforge_mod
        # First get the encrypted API token
        local token_url="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
        local encrypted_token_file=$(mktemp)

        if command -v curl >/dev/null 2>&1; then
            curl -s -L -o "$encrypted_token_file" "$token_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$encrypted_token_file" "$token_url" 2>/dev/null
        else
            rm -f "$encrypted_token_file"
            return 1
        fi

        # Decrypt the API token
        local fixed_passphrase="MinecraftSplitscreenSteamDeck2025"
        local cf_api_key
        cf_api_key=$(openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$fixed_passphrase" -in "$encrypted_token_file" 2>/dev/null)
        rm -f "$encrypted_token_file"

        if [[ -z "$cf_api_key" ]]; then
            return 1  # Can't get API key
        fi

        # Query CurseForge API with Fabric loader filter
        local cf_api_url="https://api.curseforge.com/v1/mods/$mod_id/files?modLoaderType=4"
        local tmp_body
        tmp_body=$(mktemp)
        if [[ -z "$tmp_body" ]]; then
            return 1
        fi

        # Make authenticated API request
        local http_code
        http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url")
        local version_json
        version_json=$(cat "$tmp_body")
        rm "$tmp_body"

        # Validate API response
        if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
            return 1
        fi

        # Version compatibility checking using same logic as check_curseforge_mod
        local mc_major_minor
        mc_major_minor=$(echo "$mc_version" | grep -oE '^[0-9]+\.[0-9]+')
        local mc_major_minor_x="$mc_major_minor.x"
        local mc_major_minor_0="$mc_major_minor.0"

        # CurseForge-specific jq filter for version matching (same as in check_curseforge_mod)
        local jq_filter='
            .data[]
            | select(
                ((.gameVersions[] == $mc_version) or
                (.gameVersions[] == $mc_major_minor) or
                (.gameVersions[] == $mc_major_minor_x) or
                (.gameVersions[] == $mc_major_minor_0))
              )
            | .downloadUrl
        '

        local jq_result
        jq_result=$(printf "%s" "$version_json" | jq -r \
            --arg mc_version "$mc_version" \
            --arg mc_major_minor "$mc_major_minor" \
            --arg mc_major_minor_x "$mc_major_minor_x" \
            --arg mc_major_minor_0 "$mc_major_minor_0" \
            "$jq_filter" 2>/dev/null | head -n1)

        # Return success if we found a compatible version
        if [[ -n "$jq_result" && "$jq_result" != "null" ]]; then
            return 0  # Compatible
        fi
    fi

    return 1  # Not compatible
}

# =============================================================================
# FALLBACK DATA
# =============================================================================

# @function    fallback_dependencies
# @description Provide hardcoded dependency information for critical mods when API calls fail.
# @param       $1 - mod_id: The mod ID to look up
# @param       $2 - platform: "modrinth" or "curseforge"
# @stdout      Space-separated list of dependency mod IDs, or empty string
# @return      0 always
fallback_dependencies() {
    local mod_id="$1"
    local platform="$2"

    case "$platform:$mod_id" in
        "modrinth:P7dR8mSH")  # Fabric API
            echo ""
            ;;
        "modrinth:yJgqfSDR")  # Splitscreen Support
            echo "P7dR8mSH" # Fabric API
            ;;
        "modrinth:gHvKJofA")  # Legacy4J
            echo "lhGA9TYQ P7dR8mSH nkTZHOLD"  # Architectury API, Fabric API, Factory API
            ;;
        "curseforge:317269")  # Controllable
            echo "634179"  # Framework
            ;;
        *)
            echo ""
            ;;
    esac
}

# =============================================================================
# USER INTERACTION
# =============================================================================

# @function    get_minecraft_version
# @description Interactive Minecraft version selection with intelligent compatibility checking.
#              Only offers versions that support both Controllable and Splitscreen Support mods.
# @global      MC_VERSION - (output) Set to selected Minecraft version
# @stdin       User input from /dev/tty (for curl | bash compatibility)
# @return      0 on success, exits on failure to determine versions
get_minecraft_version() {
    print_header "🎯 MINECRAFT VERSION SELECTION"

    # Get list of supported Minecraft versions
    local -a supported_versions
    readarray -t supported_versions <<< "$(get_supported_minecraft_versions)"

    # Filter out any empty entries
    local -a clean_versions=()
    for version in "${supported_versions[@]}"; do
        if [[ -n "$version" && "$version" != "null" ]]; then
            clean_versions+=("$version")
        fi
    done
    supported_versions=("${clean_versions[@]}")

    if [[ ${#supported_versions[@]} -eq 0 ]]; then
        print_error "Could not determine supported Minecraft versions. Please check your internet connection and try again."
        exit 1
    fi

    # Display supported versions to user
    echo "🎮 Available Minecraft versions (with full splitscreen mod support):"

    local counter=1
    for version in "${supported_versions[@]}"; do
        if [[ $counter -le 10 ]]; then  # Show top 10 most recent supported versions
            echo "  $counter. Minecraft $version"
            ((counter++))
        fi
    done

    echo "These versions have been verified to support both essential splitscreen mods:"
    echo "  ✅ Controllable (controller support)"
    echo "  ✅ Splitscreen Support (split-screen functionality)"

    # Get user choice
    local latest_supported="${supported_versions[0]}"
    echo "Enter your choice:"
    echo "  1-${#supported_versions[@]} = Select a specific version from the list above"
    echo "  [Enter] = Use latest supported version ($latest_supported) [RECOMMENDED]"
    echo "  custom = Enter a custom version (may not have full mod support)"
    echo "  Or directly type a Minecraft version (e.g., 1.21.3)"

    local user_choice
    # Use centralized prompt function that handles curl | bash piping
    user_choice=$(prompt_user "Your choice [latest]: " "latest" 60)

    if [[ -z "$user_choice" || "$user_choice" == "latest" ]]; then
        # Use latest supported version
        MC_VERSION="$latest_supported"
        print_success "Using latest supported version: $MC_VERSION"

    elif [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ $user_choice -ge 1 && $user_choice -le ${#supported_versions[@]} ]]; then
        # User selected a number from the list
        local selected_index=$((user_choice - 1))
        MC_VERSION="${supported_versions[$selected_index]}"
        print_success "Using selected version: $MC_VERSION"

    elif [[ "$user_choice" == "custom" ]]; then
        # User wants to enter a custom version
        local custom_version
        custom_version=$(prompt_user "Enter custom Minecraft version (e.g., 1.21.3): " "" 60)
        if [[ -n "$custom_version" ]]; then
            MC_VERSION="$custom_version"
            print_warning "Using custom version: $MC_VERSION"
            print_warning "⚠️  This version may not support all required splitscreen mods!"
            print_info "If installation fails, try using a supported version from the list above."
        else
            print_warning "No version entered, using latest supported: $latest_supported"
            MC_VERSION="$latest_supported"
        fi

    elif [[ "$user_choice" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        # User directly entered a version number (e.g., 1.21.3, 1.21, etc.)
        MC_VERSION="$user_choice"

        # Check if it's in the supported list
        local is_supported=false
        for supported_ver in "${supported_versions[@]}"; do
            if [[ "$supported_ver" == "$MC_VERSION" ]]; then
                is_supported=true
                break
            fi
        done

        if [[ "$is_supported" == true ]]; then
            print_success "Using directly entered supported version: $MC_VERSION"
        else
            print_warning "Using directly entered version: $MC_VERSION"
            print_warning "⚠️  This version may not support all required splitscreen mods!"
            print_info "If installation fails, try using a supported version from the list above."
        fi

    else
        # Invalid input, use latest supported
        print_warning "Invalid choice, using latest supported version: $latest_supported"
        MC_VERSION="$latest_supported"
    fi
    print_info "Selected Minecraft version: $MC_VERSION"
}

# =============================================================================
# FABRIC VERSION DETECTION
# =============================================================================

# @function    get_fabric_version
# @description Fetch the latest Fabric loader version from official Fabric Meta API.
#              Fabric loader provides the mod loading framework for Minecraft.
# @global      FABRIC_VERSION - (output) Set to detected Fabric version
# @return      0 always (uses fallback on API failure)
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
