#!/bin/bash
# =============================================================================
# VERSION MANAGEMENT MODULE
# =============================================================================
# Minecraft and Fabric version selection and detection functions
# Intelligent version selection based on required mod compatibility

# get_supported_minecraft_versions: Check what Minecraft versions support required mods
# Queries APIs for every mod in REQUIRED_SPLITSCREEN_MODS/IDS/PLATFORMS (loaded from
# mods.conf's "required" entries — Controlify plus the standard performance set) to
# find compatible versions. Splitscreen tiling is done by KWin, not a mod, as of
# 2026-06-23 — Splitscreen Support is no longer installed/required.
# Returns: Array of supported Minecraft versions in descending order (newest first)
get_supported_minecraft_versions() {
    if [[ -n "${EXTRA_REQUIRED_MOD_ID:-}" && -n "${EXTRA_REQUIRED_MOD_PLATFORM:-}" ]]; then
        print_progress "Checking supported Minecraft versions for core mods + ${EXTRA_REQUIRED_MOD_NAME:-custom mod}..." >&2
    else
        print_progress "Checking supported Minecraft versions for essential splitscreen mods..." >&2
    fi
    
    local -a supported_versions=()
    local -a all_versions=()
    
    # Get all Minecraft versions from Mojang API
    # Fix #51 (D14): fetch_url replaces the bare curl call.
    local mojang_versions
    mojang_versions=$(fetch_url \
        "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" - \
        2>/dev/null \
        | jq -r '.versions[] | select(.type=="release") | .id' 2>/dev/null)
    
    if [[ -z "$mojang_versions" ]]; then
        print_error "Could not fetch Minecraft versions from Mojang API" >&2
        print_error "Please check your internet connection and try again" >&2
        return 1
    else
        # Take the 20 most-recent release versions. Mojang returns newest-first.
        # 20 covers the current year's releases (26.0, 26.1, 26.1.1 …) plus several
        # prior-year versions so older mod support is still visible.
        readarray -t all_versions <<< "$mojang_versions"
        all_versions=("${all_versions[@]:0:20}")
    fi
    
    print_info "Checking compatibility for required splitscreen mods..." >&2
    
    # Optional extra required mod constraint (used when user asks to switch versions
    # to support a specific custom mod in addition to the two required core mods).
    local extra_mod_id="${EXTRA_REQUIRED_MOD_ID:-}"
    local extra_mod_platform="${EXTRA_REQUIRED_MOD_PLATFORM:-}"
    local extra_mod_name="${EXTRA_REQUIRED_MOD_NAME:-Custom mod}"

    # Check each Minecraft version for compatibility with core required mods,
    # and optionally with an extra custom mod requirement.
    for mc_version in "${all_versions[@]}"; do
        print_progress "  Testing $mc_version..." >&2

        # Every required mod (Controlify + the standard performance set from
        # mods.conf) must be available for this MC version, or the version is
        # dropped — required mods that silently fail to install defeat the
        # point of calling them "required".
        local required_mods_compatible=true
        local missing_required=""
        for i in "${!REQUIRED_SPLITSCREEN_IDS[@]}"; do
            if ! check_mod_version_compatibility "${REQUIRED_SPLITSCREEN_IDS[$i]}" "${REQUIRED_SPLITSCREEN_PLATFORMS[$i]}" "$mc_version"; then
                required_mods_compatible=false
                missing_required="${missing_required}${missing_required:+, }${REQUIRED_SPLITSCREEN_MODS[$i]:-${REQUIRED_SPLITSCREEN_IDS[$i]}}"
            fi
        done

        local extra_mod_compatible=true
        if [[ -n "$extra_mod_id" && -n "$extra_mod_platform" ]]; then
            if ! check_mod_version_compatibility "$extra_mod_id" "$extra_mod_platform" "$mc_version" "true"; then
                extra_mod_compatible=false
            fi
        fi

        # Only include versions where all required mods are available,
        # and custom required mod too when specified.
        if [[ "$required_mods_compatible" == true && "$extra_mod_compatible" == true ]]; then
            supported_versions+=("$mc_version")
            if [[ -n "$extra_mod_id" && -n "$extra_mod_platform" ]]; then
                print_success "    ✅ $mc_version - Required mods + $extra_mod_name compatible" >&2
            else
                print_success "    ✅ $mc_version - All required mods compatible" >&2
            fi
        else
            if [[ "$required_mods_compatible" != true ]]; then
                print_info "    ❌ $mc_version - Missing required mod support: $missing_required" >&2
            elif [[ -n "$extra_mod_id" && -n "$extra_mod_platform" ]]; then
                print_info "    ❌ $mc_version - Missing support for $extra_mod_name" >&2
            fi
        fi
    done
    
    if [[ ${#supported_versions[@]} -eq 0 ]]; then
        if [[ -n "$extra_mod_id" && -n "$extra_mod_platform" ]]; then
            print_error "No Minecraft versions found that support both required core mods and $extra_mod_name." >&2
            print_error "This may be due to exact-version compatibility limits in the selected custom mod." >&2
        else
            print_error "No Minecraft versions found with both required mods available!" >&2
            print_error "This may be due to API issues. Please try again later or check your internet connection." >&2
        fi
        return 1
    fi
    
    # Return the supported versions array (to stdout only)
    printf '%s\n' "${supported_versions[@]}"
}

# check_mod_version_compatibility: Check if a specific mod supports a specific MC version
# This is a lightweight version check that doesn't add mods to arrays
# Parameters:
#   $1 - mod_id: Mod ID (Modrinth project ID or CurseForge project ID)
#   $2 - platform: "modrinth" or "curseforge"
#   $3 - mc_version: Minecraft version to check.
#        Supports both legacy format (e.g. "1.21.3") and the new yearly format
#        introduced in 2026 (e.g. "26.0", "26.1", "26.1.1" = year.release[.patch]).
# Returns: 0 if compatible, 1 if not compatible
check_mod_version_compatibility() {
    local mod_id="$1"
    local platform="$2"
    local mc_version="$3"
    local strict_mode="${4:-false}"  # true = exact MC version only
    
    if [[ "$platform" == "modrinth" ]]; then
        # Check Modrinth mod for version compatibility using same logic as check_modrinth_mod
        local api_url="${MODRINTH_API_BASE}/project/$mod_id/version"
        local tmp_body
        tmp_body=$(mktemp)
        if [[ -z "$tmp_body" ]]; then
            return 1
        fi
        
        # Fetch version data from Modrinth API
        # Fix #51 (D14): fetch_url_status replaces the bare curl -w call.
        local http_code
        http_code=$(fetch_url_status "$api_url" "$tmp_body")
        local version_json
        version_json=$(cat "$tmp_body")
        rm "$tmp_body"
        
        # Validate API response
        if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
            return 1
        fi
        
        # Fix #88: canonical Modrinth ladder from mod_management.sh (which
        # owns the version-match policy — ARCHITECTURE.md §2) instead of
        # reimplementing it. check_standalone=0: this call site computed a
        # has_standalone_major_minor value in the pre-dedup copy but never
        # actually used it to block fallback (a dead variable) — passing 0
        # reproduces that exact (weaker) guard rather than silently
        # tightening it as part of this cleanup. strict_mode still means
        # "exact match only, no ladder", same as before.
        local file_url=""
        if [[ "$strict_mode" == "true" ]]; then
            file_url=$(_modrinth_tier_match "$version_json" "$mc_version")
            file_url="${file_url%%$'\t'*}"
        else
            local match
            if match=$(match_modrinth_version "$version_json" \
                "$mc_version" 0); then
                file_url="${match%%$'\t'*}"
            fi
        fi

        # Return success if we found a compatible version
        if [[ -n "$file_url" && "$file_url" != "null" ]]; then
            return 0  # Compatible
        fi

    elif [[ "$platform" == "curseforge" ]]; then
        # Fix #47: single canonical token fetch+decrypt (was a 7x-copied
        # download+openssl-decrypt block).
        local cf_api_key
        if ! cf_api_key=$(get_curseforge_api_token 2>/dev/null) \
            || [[ -z "$cf_api_key" ]]; then
            return 1  # Can't get API key
        fi

        # Query CurseForge API with Fabric loader filter
        local cf_api_url="${CURSEFORGE_API_BASE:-https://api.curseforge.com/v1}"
        cf_api_url="${cf_api_url}/mods/$mod_id/files?modLoaderType=4"
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

        # Fix #88: canonical CurseForge ladder from mod_management.sh
        # (which owns the version-match policy — ARCHITECTURE.md §2).
        # allow_fallback mirrors strict_mode exactly: with allow_fallback
        # "0" the shared jq filter degrades to the same exact-only match
        # the pre-dedup copy's separate strict jq_filter performed. NOTE
        # this call site's non-strict guard never gated the fallback on
        # patch-safety at all (unlike check_curseforge_mod's guard, which
        # DOES) — a pre-existing divergence, preserved here by always
        # passing "1" when not strict rather than silently tightening it
        # as part of this cleanup.
        local allow_fallback="1"
        [[ "$strict_mode" == "true" ]] && allow_fallback="0"
        local match
        if match=$(match_curseforge_version "$version_json" "$mc_version" \
            "$allow_fallback") && [[ -n "$match" ]]; then
            return 0  # Compatible
        fi
    fi
    
    return 1  # Not compatible
}

# Add fallback dependencies for critical mods when API calls fail
fallback_dependencies() {
    local mod_id="$1"
    local platform="$2"
    
    case "$platform:$mod_id" in
        "modrinth:P7dR8mSH")  # Fabric API
            echo ""
            ;;
        "modrinth:DOUdJVEm")  # Controlify
            echo "P7dR8mSH"  # Fabric API
            ;;
        *)
            echo ""
            ;;
    esac
}

# get_minecraft_version: Get target Minecraft version with intelligent compatibility checking
# Only offers versions that support every required mod (window tiling is done by
# KWin, not a mod)
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
        return 1
    fi
    
    # Display supported versions to user
    if [[ -n "${EXTRA_REQUIRED_MOD_ID:-}" && -n "${EXTRA_REQUIRED_MOD_PLATFORM:-}" ]]; then
        echo "🎮 Available Minecraft versions (core mods + ${EXTRA_REQUIRED_MOD_NAME:-custom mod} support):"
    else
        echo "🎮 Available Minecraft versions (with full splitscreen mod support):"
    fi
    
    local counter=1
    for version in "${supported_versions[@]}"; do
        if [[ $counter -le 10 ]]; then  # Show top 10 most recent supported versions
            echo "  $counter. Minecraft $version"
            counter=$((counter + 1))
        fi
    done
    
    echo "These versions have been verified to support the required mod:"
    echo "  ✅ Controlify (controller support)"
    if [[ -n "${EXTRA_REQUIRED_MOD_ID:-}" && -n "${EXTRA_REQUIRED_MOD_PLATFORM:-}" ]]; then
        echo "  ✅ ${EXTRA_REQUIRED_MOD_NAME:-Requested custom mod}"
    fi
    
    # Get user choice
    local latest_supported="${supported_versions[0]}"
    echo "Enter your choice:"
    echo "  1-${#supported_versions[@]} = Select a specific version from the list above"
    echo "  [Enter] = Use latest supported version ($latest_supported) [RECOMMENDED]"
    
    local user_choice
    read -p "Your choice [latest]: " user_choice
    
    if [[ -z "$user_choice" || "$user_choice" == "latest" ]]; then
        # Use latest supported version
        MC_VERSION="$latest_supported"
        print_success "Using latest supported version: $MC_VERSION"
        
    elif [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ $user_choice -ge 1 && $user_choice -le ${#supported_versions[@]} ]]; then
        # User selected a number from the list
        local selected_index=$((user_choice - 1))
        MC_VERSION="${supported_versions[$selected_index]}"
        print_success "Using selected version: $MC_VERSION"
        
    else
        # Invalid input, use latest supported
        print_warning "Invalid choice, using latest supported version: $latest_supported"
        MC_VERSION="$latest_supported"
    fi
    print_info "Selected Minecraft version: $MC_VERSION"
}

# get_fabric_version: Fetch the latest Fabric loader version from official API
# Fabric loader provides the mod loading framework for Minecraft
get_fabric_version() {
    print_progress "Detecting latest Fabric loader version..."
    
    # Query Fabric Meta API for the latest loader version
    # Fix #51 (D14): fetch_url replaces the bare curl call.
    FABRIC_VERSION=$(fetch_url "${FABRIC_META_BASE}/versions/loader" - \
        | jq -r '.[0].version' 2>/dev/null)
    
    # Fallback to known stable version if API call fails
    if [[ -z "$FABRIC_VERSION" || "$FABRIC_VERSION" == "null" ]]; then
        print_warning "Could not detect latest Fabric version, using fallback"
        FABRIC_VERSION="0.16.9"  # Known stable version that works with most mods
    fi
    
    print_success "Using Fabric loader version: $FABRIC_VERSION"
}
