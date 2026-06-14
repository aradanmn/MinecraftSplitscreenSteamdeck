#!/bin/bash
# =============================================================================
# MOD MANAGEMENT MODULE
# =============================================================================
# Mod compatibility checking, dependency resolution, and user selection functions
# Handles both Modrinth and CurseForge platforms

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
        # Use || true to prevent set -e from exiting on mod check failures
        if [[ "$MOD_TYPE" == "modrinth" ]]; then
            check_modrinth_mod "$MOD_NAME" "$MOD_ID" || true
        elif [[ "$MOD_TYPE" == "curseforge" ]]; then
            check_curseforge_mod "$MOD_NAME" "$MOD_ID" || true
        fi
    done
    
    print_success "Mod compatibility check completed"
    local supported_count=0
    if [[ ${#SUPPORTED_MODS[@]} -gt 0 ]]; then
        supported_count=${#SUPPORTED_MODS[@]}
    fi
    print_info "Found $supported_count compatible mods for Minecraft $MC_VERSION"
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
    # Legacy example: "1.21.3". New yearly-format example: "26.1.1" or "26.1".
    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
    fi
    
    # STAGE 2: Try major.minor version match if exact match failed.
    # Legacy: "1.21.3" -> try "1.21", "1.21.x", "1.21.0"
    # New:    "26.1.1" -> try "26.1", "26.1.x", "26.1.0" (same logic, format-agnostic)
    # BUT ONLY if no specific patch version exists that's higher than what we're looking for
    if [[ -z "$file_url" || "$file_url" == "null" ]]; then
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')  # "1.21" from "1.21.3" or "26.1" from "26.1.1"
        
        # Before trying major.minor match, check if this version is higher than existing patch versions
        # This prevents matching 1.21 when looking for 1.21.6 if the highest patch version is only 1.21.5
        local mc_patch_version
        mc_patch_version=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')
        local should_try_fallback=true
        
        # If we have a patch version (e.g. 1.21.6), check if it's higher than any available versions
        if [[ -n "$mc_patch_version" ]]; then
            # Check if there's a standalone major.minor version (e.g., "1.21" without patch)
            local has_standalone_major_minor
            has_standalone_major_minor=$(printf "%s" "$version_json" | jq -r --arg major_minor "$mc_major_minor" '
                .[]
                | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $major_minor))
                | .version_number' 2>/dev/null | head -n1)
            
            # Get the highest patch version available for this major.minor series
            local highest_patch
            highest_patch=$(printf "%s" "$version_json" | jq -r --arg major_minor "$mc_major_minor" '
                [
                  .[]
                  | select(.loaders[]? == "fabric")
                  | .game_versions[]?
                  | select(startswith($major_minor + ".") and (split(".") | length == 3))
                  | (split(".")[2] | tonumber?)
                ]
                | map(select(. != null))
                | if length > 0 then max else empty end' 2>/dev/null)
            
            # Don't try fallback if:
            # 1. There's a standalone major.minor version (e.g., "1.21") and we're requesting a patch version, OR
            # 2. There are patch versions and our requested patch is higher than the highest available
            if [[ -n "$has_standalone_major_minor" && "$has_standalone_major_minor" != "null" ]] || 
               [[ -n "$highest_patch" && "$highest_patch" != "null" && "$mc_patch_version" -gt "$highest_patch" ]]; then
                should_try_fallback=false
            fi
        fi
        
        # Only try major.minor fallback if it's safe to do so
        if [[ "$should_try_fallback" == true ]]; then
            # Try exact major.minor (e.g., "1.21")
            file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
            if [[ -n "$file_url" && "$file_url" != "null" ]]; then
                dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
            fi
            
            # Try wildcard version format (e.g., "1.21.x") 
            if [[ -z "$file_url" || "$file_url" == "null" ]]; then
                local mc_major_minor_x="$mc_major_minor.x"
                file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
                if [[ -n "$file_url" && "$file_url" != "null" ]]; then
                    dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
                fi
            fi
            
            # Try zero-padded version format (e.g., "1.21.0")
            if [[ -z "$file_url" || "$file_url" == "null" ]]; then
                local mc_major_minor_0="$mc_major_minor.0"
                file_url=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
                if [[ -n "$file_url" && "$file_url" != "null" ]]; then
                    dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$mc_major_minor_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
                fi
            fi
        fi
        
        # DISABLED: Limited prefix matching - this was allowing false positives
        # We've disabled this section to prevent matching lower patch versions
        # when a higher patch version is requested that doesn't exist
        # (e.g., preventing 1.21.5 from matching when 1.21.6 is requested)
    fi
    
    # STAGE 3: Advanced pattern matching with comprehensive version range support
    # This handles complex version patterns like ranges, wildcards, and edge cases
    if [[ -z "$file_url" || "$file_url" == "null" ]]; then
        dep_ids=""   # Reset dependencies
        local mc_major_minor
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
        local mc_major_minor_x="$mc_major_minor.x"
        local mc_major_minor_0="$mc_major_minor.0"
        
        # Apply the same fallback safety check as in STAGE 2
        local mc_patch_version
        mc_patch_version=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')
        local should_try_stage3_fallback=true
        
        # If we have a patch version, check if it's higher than any available versions
        if [[ -n "$mc_patch_version" ]]; then
            # Check if there's a standalone major.minor version (e.g., "1.21" without patch)
            local has_standalone_major_minor
            has_standalone_major_minor=$(printf "%s" "$version_json" | jq -r --arg major_minor "$mc_major_minor" '
                .[]
                | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $major_minor))
                | .version_number' 2>/dev/null | head -n1)
            
            # Get the highest patch version available for this major.minor series
            local highest_patch
            highest_patch=$(printf "%s" "$version_json" | jq -r --arg major_minor "$mc_major_minor" '
                [
                  .[]
                  | select(.loaders[]? == "fabric")
                  | .game_versions[]?
                  | select(startswith($major_minor + ".") and (split(".") | length == 3))
                  | (split(".")[2] | tonumber?)
                ]
                | map(select(. != null))
                | if length > 0 then max else empty end' 2>/dev/null)
            
            # Don't try fallback if:
            # 1. There's a standalone major.minor version (e.g., "1.21") and we're requesting a patch version, OR
            # 2. There are patch versions and our requested patch is higher than the highest available
            if [[ -n "$has_standalone_major_minor" && "$has_standalone_major_minor" != "null" ]] || 
               [[ -n "$highest_patch" && "$highest_patch" != "null" && "$mc_patch_version" -gt "$highest_patch" ]]; then
                should_try_stage3_fallback=false
            fi
        fi
        
        # Only proceed with STAGE 3 if fallback is safe
        if [[ "$should_try_stage3_fallback" == true ]]; then
            # Simplified and corrected jq filter with stricter version matching
            # Fixed: game_versions is always at release level in Modrinth API, not file level
            # Made version matching more strict to avoid false positives
            local jq_filter='
              .[] as $release
              | select($release.loaders[] == "fabric")
              | select(
                  $release.game_versions[]
                  | (. == $mc_version or
                     . == $mc_major_minor or
                     . == $mc_major_minor_x or
                     . == $mc_major_minor_0)
                )
              | $release.files[]
              | select(.primary == true)
              | {
                  url,
                  dependencies: ($release.dependencies // [] | map(select(.dependency_type == "required") | .project_id))
                }
              | @base64
            '
        
            # Execute the corrected jq filter with all version variants
            local jq_result
            jq_result=$(printf "%s" "$version_json" | jq -r \
              --arg mc_version "$MC_VERSION" \
              --arg mc_major_minor "$mc_major_minor" \
              --arg mc_major_minor_x "$mc_major_minor_x" \
              --arg mc_major_minor_0 "$mc_major_minor_0" \
              "$jq_filter" 2>/dev/null | head -n1)

            # Decode the base64-encoded result and extract URL and dependencies
            if [[ -n "$jq_result" && "$jq_result" != "null" ]]; then
                local decoded
                if decoded=$(echo "$jq_result" | base64 --decode 2>/dev/null); then
                    file_url=$(echo "$decoded" | jq -r '.url' 2>/dev/null)
                    dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' 2>/dev/null | tr '\n' ' ')
                fi
            fi
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
        return 0
    else
        local fabric_release_count=0
        if command -v jq >/dev/null 2>&1; then
            fabric_release_count=$(printf "%s" "$version_json" | jq -r '[.[] | select(any(.loaders[]?; . == "fabric"))] | length' 2>/dev/null || echo "0")
        fi
        if [[ "$fabric_release_count" == "0" ]]; then
            print_warning "❌ $mod_name ($mod_id) - no Fabric versions found on Modrinth"
        else
            print_warning "❌ $mod_name ($mod_id) - no compatible Fabric version for Minecraft $MC_VERSION"
        fi
        return 1
    fi
}

# check_curseforge_mod: Check CurseForge mod compatibility with encrypted API access
# CurseForge requires API key authentication and has more restrictive access
# API token is encrypted and stored in the GitHub repository for security
check_curseforge_mod() {
    local mod_name="$1"           # Human-readable mod name
    local cf_project_id="$2"      # CurseForge project ID (numeric)
    local file_url=""
    local dep_ids=""
    
    # Simplified CurseForge API access using a simpler method
    # Instead of the complex encrypted token approach, use alternative method
    local cf_api_key=""
    
    # Try to use a simple decryption method for the token
    local cf_token_enc_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
    local tmp_token_file
    
    # Create temporary file for encrypted token download with timeout
    tmp_token_file=$(mktemp)
    if [[ -z "$tmp_token_file" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi
    
    # Download with timeout to prevent hanging
    local http_code
    http_code=$(timeout 10 curl -s -L -w "%{http_code}" -o "$tmp_token_file" "$cf_token_enc_url" 2>/dev/null)
    local curl_exit=$?
    
    if [[ $curl_exit -eq 124 ]]; then
        print_warning "CurseForge API token download timed out for $mod_name"
        rm -f "$tmp_token_file"
        return 1
    elif [[ "$http_code" != "200" ]] || [[ ! -s "$tmp_token_file" ]]; then
        print_warning "Failed to download CurseForge API token (HTTP: $http_code)"
        rm -f "$tmp_token_file"
        return 1
    fi
    
    # Decrypt API token using OpenSSL (requires passphrase hardcoded for automation)
    if command -v openssl >/dev/null 2>&1; then
        cf_api_key=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$tmp_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    else
        print_warning "OpenSSL not available for token decryption for $mod_name (skipping)"
        rm -f "$tmp_token_file"
        return 1
    fi
    
    # Clean up temp file immediately
    rm -f "$tmp_token_file"
    
    # If OpenSSL decryption failed, skip this mod
    if [[ -z "$cf_api_key" ]]; then
        print_warning "Failed to decrypt CurseForge API token for $mod_name (skipping)"
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
    
    # Make authenticated API request to CurseForge with timeout
    http_code=$(timeout 15 curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $cf_api_key" "$cf_api_url" 2>/dev/null)
    local curl_exit=$?
    local version_json
    version_json=$(cat "$tmp_body")
    rm "$tmp_body"
    
    # Check for timeout or API failure
    if [[ $curl_exit -eq 124 ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - CurseForge API timeout"
        return 1
    elif [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . > /dev/null 2>&1; then
        print_warning "❌ $mod_name ($cf_project_id) - API error (HTTP $http_code)"
        return 1
    fi
    
    # Version compatibility checking for CurseForge mods
    # Uses same versioning logic as Modrinth but with CurseForge API structure
    local mc_major_minor
    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    local mc_major_minor_x="$mc_major_minor.x"
    local mc_major_minor_0="$mc_major_minor.0"
    local mc_patch_version
    mc_patch_version=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')
    local should_try_fallback=true

    # Apply strict fallback guard for patch releases:
    # - If a standalone major.minor exists (e.g., 1.21), don't assume compatibility for patch requests.
    # - If requested patch is newer than highest published patch, don't fallback to older variants.
    if [[ -n "$mc_patch_version" ]]; then
        local has_standalone_major_minor
        has_standalone_major_minor=$(printf "%s" "$version_json" | jq -r --arg mm "$mc_major_minor" '
            .data[]
            | select(any(.gameVersions[]?; . == $mm))
            | .id' 2>/dev/null | head -n1)

        local highest_patch
        highest_patch=$(printf "%s" "$version_json" | jq -r --arg mm "$mc_major_minor" '
            [
              .data[]?
              | .gameVersions[]?
              | select(startswith($mm + ".") and (split(".") | length == 3))
              | (split(".")[2] | tonumber?)
            ]
            | map(select(. != null))
            | if length > 0 then max else empty end' 2>/dev/null)

        if [[ -n "$has_standalone_major_minor" && "$has_standalone_major_minor" != "null" ]] || \
           [[ -n "$highest_patch" && "$highest_patch" != "null" && "$mc_patch_version" -gt "$highest_patch" ]]; then
            should_try_fallback=false
        fi
    fi
    
    # CurseForge-specific jq filter for version matching
    # Checks gameVersions array and extracts downloadUrl and dependencies
    # relationType == 3 means "required dependency" in CurseForge API
    local jq_filter='
        .data[]
        | select(
            (.gameVersions[] == $mc_version) or
            (
              $allow_fallback == "true" and
              (
                (.gameVersions[] == $mc_major_minor) or
                (.gameVersions[] == $mc_major_minor_x) or
                (.gameVersions[] == $mc_major_minor_0)
              )
            )
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
        --arg allow_fallback "$should_try_fallback" \
        "$jq_filter" 2>/dev/null | head -n1)
    
    # Process the result if we found a compatible version
    if [[ -n "$jq_result" ]]; then
        local decoded
        decoded=$(echo "$jq_result" | base64 --decode)
        file_url=$(echo "$decoded" | jq -r '.url')
        dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
        
        # Add to supported mods list with CurseForge-specific information
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")                 # Placeholder for description
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$cf_project_id")           # Store numeric CurseForge project ID
        MOD_TYPES+=("curseforge")             # Mark as CurseForge mod
        MOD_DEPENDENCIES+=("$dep_ids")        # Store CurseForge dependency IDs
        print_success "✅ $mod_name (CurseForge)"
        return 0
    else
        local fabric_file_count=0
        if command -v jq >/dev/null 2>&1; then
            fabric_file_count=$(printf "%s" "$version_json" | jq -r '.data | length' 2>/dev/null || echo "0")
        fi
        if [[ "$fabric_file_count" == "0" ]]; then
            print_warning "❌ $mod_name ($cf_project_id) - no Fabric files found on CurseForge"
        else
            print_warning "❌ $mod_name ($cf_project_id) - no compatible Fabric file for Minecraft $MC_VERSION"
        fi
        return 1
    fi
}

# resolve_all_dependencies: Main function to automatically resolve all mod dependencies
# This function builds a complete dependency tree and ensures all required mods are included
# Parameters: None (operates on FINAL_MOD_INDEXES global array)
resolve_all_dependencies() {
    print_header "🔗 AUTOMATIC DEPENDENCY RESOLUTION"
    print_progress "Automatically resolving mod dependencies..."
    
    # Check if we have any mods to process
    local final_mod_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        final_mod_count=${#FINAL_MOD_INDEXES[@]}
    fi
    if [[ $final_mod_count -eq 0 ]]; then
        print_info "No mods selected for dependency resolution"
        return 0
    fi
    
    local initial_mod_count=$final_mod_count
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
                    # Validate dependency ID format - skip invalid IDs that look like mod names
                    if [[ "$dep_id" =~ ^[A-Za-z]+$ ]] && [[ ${#dep_id} -gt 12 ]]; then
                        print_warning "       → Skipping invalid dependency ID (appears to be mod name): $dep_id"
                        continue
                    fi
                    
                    # Additional validation - CurseForge IDs should be numeric, Modrinth IDs should be alphanumeric with specific patterns
                    if [[ "$dep_id" =~ ^[0-9]+$ ]]; then
                        # Valid CurseForge ID (numeric)
                        dep_platform="curseforge"
                    elif [[ "$dep_id" =~ ^[A-Za-z0-9]{6,12}$ ]] || [[ "$dep_id" =~ ^[A-Za-z0-9_-]{3,}$ ]]; then
                        # Valid Modrinth ID (alphanumeric, 6-12 chars, or with dashes/underscores)
                        dep_platform="modrinth"
                    else
                        print_warning "       → Skipping dependency with invalid ID format: $dep_id"
                        continue
                    fi
                    
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
                        
                        # Fetch external dependency (timeout handled within the function)
                        if fetch_and_add_external_mod "$dep_id" "$dep_platform"; then
                            print_info "       → Successfully added external dependency: $dep_id"
                        else
                            print_warning "       → Failed to fetch external dependency: $dep_id"
                            print_info "         (This is often due to version incompatibility and can be safely ignored)"
                        fi
                    fi
                fi
            done
        else
            print_info "     → No dependencies found"
        fi
    done
    
    local updated_mod_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        updated_mod_count=${#FINAL_MOD_INDEXES[@]}
    fi
    local added_count=$((updated_mod_count - initial_mod_count))
    
    print_success "Dependency resolution complete!"
    print_info "Added $added_count dependencies ($initial_mod_count → $updated_mod_count total mods)"
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
    local cf_token_enc_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
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
    
    # Decrypt API token using OpenSSL (requires passphrase hardcoded for automation)
    local cf_api_key
    if command -v openssl >/dev/null 2>&1; then
        cf_api_key=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$tmp_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    else
        rm "$tmp_token_file"
        return 1
    fi
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
        mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')  # "1.21" from "1.21.3" or "26.1" from "26.1.1"
        
        # Simple jq filter to get dependencies from compatible fabric versions with strict matching
        # Use temporary file to avoid command line length limits
        dependencies=$(jq -r "
            .[] 
            | select(.loaders[]? == \"fabric\") 
            | select(.game_versions[]? | (. == \"$MC_VERSION\" or . == \"$mc_major_minor\" or . == \"${mc_major_minor}.x\" or . == \"${mc_major_minor}.0\"))
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
    
    # Use fallback dependencies if API call failed
    if [[ -z "$dependencies" ]]; then
        dependencies=$(fallback_dependencies "$mod_id" "modrinth")
    fi
    
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
    local token_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
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
            
            # Extract file ID from the most recent compatible file with strict version matching
            local file_id=$(jq -r --arg v "$MC_VERSION" --arg mmv "$mc_major_minor" '.data[] | select(.gameVersions[] == $v or .gameVersions[] == $mmv or .gameVersions[] == ($mmv + ".x") or .gameVersions[] == ($mmv + ".0")) | .id' "$files_temp" 2>/dev/null | head -n1)
            
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
    
    # Use fallback dependencies if API call failed
    if [[ -z "$dependencies" ]]; then
        dependencies=$(fallback_dependencies "$mod_id" "curseforge")
    fi
    # Critical dependency fallbacks (legacy 1.21.1 era — kept for backward compat)
    if [[ -z "$dependencies" ]]; then
        case "$mod_id" in
            "238222")  # JEI
                dependencies="306612"  # Fabric API
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
            local token_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
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
                    "DOUdJVEm")  # Controlify
                        mod_title="Controlify"
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
    local token_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
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
        local mc_patch_version
        mc_patch_version=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')
        local should_try_fallback=true

        if [[ -n "$mc_patch_version" ]]; then
            local has_standalone_major_minor
            has_standalone_major_minor=$(jq -r --arg mm "$mc_major_minor" '
                .data[]?
                | select(any(.gameVersions[]?; . == $mm))
                | .id' "$temp_file" 2>/dev/null | head -n1)

            local highest_patch
            highest_patch=$(jq -r --arg mm "$mc_major_minor" '
                [
                  .data[]?
                  | .gameVersions[]?
                  | select(startswith($mm + ".") and (split(".") | length == 3))
                  | (split(".")[2] | tonumber?)
                ]
                | map(select(. != null))
                | if length > 0 then max else empty end' "$temp_file" 2>/dev/null)

            if [[ -n "$has_standalone_major_minor" && "$has_standalone_major_minor" != "null" ]] || \
               [[ -n "$highest_patch" && "$highest_patch" != "null" && "$mc_patch_version" -gt "$highest_patch" ]]; then
                should_try_fallback=false
            fi
        fi
        
        # Try exact version match first
        download_url=$(jq -r --arg v "$MC_VERSION" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        
        # Try major.minor version if exact match failed and fallback is allowed
        if [[ "$should_try_fallback" == true ]] && [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url=$(jq -r --arg v "$mc_major_minor" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        fi
        
        # Try wildcard version (e.g., "1.21.x") if fallback is allowed
        if [[ "$should_try_fallback" == true ]] && [[ -z "$download_url" || "$download_url" == "null" ]]; then
            local mc_major_minor_x="$mc_major_minor.x"
            download_url=$(jq -r --arg v "$mc_major_minor_x" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
        fi
        
        # Try limited previous patch version when fallback is allowed
        if [[ "$should_try_fallback" == true ]] && [[ -z "$download_url" || "$download_url" == "null" ]]; then
            if [[ -n "$mc_patch_version" && $mc_patch_version -gt 0 ]]; then
                # Try one patch version down (e.g., if looking for 1.21.6, try 1.21.5)
                local prev_patch=$((mc_patch_version - 1))
                local mc_prev_version="$mc_major_minor.$prev_patch"
                download_url=$(jq -r --arg v "$mc_prev_version" '.data[]? | select(.gameVersions[]? == $v) | .downloadUrl' "$temp_file" 2>/dev/null | head -n1)
            fi
        fi
    fi
    
    rm -f "$temp_file"
    
    # Return the download URL (may be empty if not found)
    echo "$download_url"
}

# get_curseforge_api_token: Download and decrypt CurseForge API token
# Returns: token string on stdout, or empty on failure
get_curseforge_api_token() {
    local token_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main/token.enc"
    local encrypted_token_file
    encrypted_token_file=$(mktemp)
    local http_code=""

    if [[ -z "$encrypted_token_file" ]]; then
        echo ""
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        http_code=$(curl -s -w "%{http_code}" -o "$encrypted_token_file" "$token_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$encrypted_token_file" "$token_url" 2>/dev/null; then
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

    local api_token=""
    if command -v openssl >/dev/null 2>&1; then
        api_token=$(openssl enc -d -aes-256-cbc -a -pbkdf2 -in "$encrypted_token_file" -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    fi

    rm -f "$encrypted_token_file"
    echo "$api_token"
}

# parse_custom_mod_input: Parse Modrinth/CurseForge custom mod input
# Supports URLs, prefixed IDs (mr:/cf:), raw Modrinth IDs/slugs, and numeric CurseForge IDs
# Parameters:
#   $1 - raw user input
#   $2 - output platform nameref (modrinth/curseforge)
#   $3 - output ID nameref
parse_custom_mod_input() {
    local raw_input="$1"
    local -n out_platform="$2"
    local -n out_id="$3"
    out_platform=""
    out_id=""

    # Trim leading/trailing whitespace
    local cleaned
    cleaned=$(echo "$raw_input" | xargs 2>/dev/null || echo "$raw_input")
    if [[ -z "$cleaned" ]]; then
        return 1
    fi

    # Modrinth URLs (modrinth.com/mod/<id-or-slug>)
    if [[ "$cleaned" =~ modrinth\.com/(mod|plugin|datapack|resourcepack|shader)/([^/?#]+) ]]; then
        out_platform="modrinth"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi

    # CurseForge URLs with numeric project IDs (.../projects/<id>)
    if [[ "$cleaned" =~ curseforge\.com/.*/projects/([0-9]+) ]]; then
        out_platform="curseforge"
        out_id="${BASH_REMATCH[1]}"
        return 0
    fi

    # Explicit prefixes
    if [[ "$cleaned" =~ ^(modrinth|mr):([A-Za-z0-9_-]+)$ ]]; then
        out_platform="modrinth"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$cleaned" =~ ^(curseforge|cf):([0-9]+)$ ]]; then
        out_platform="curseforge"
        out_id="${BASH_REMATCH[2]}"
        return 0
    fi

    # Raw numeric values are treated as CurseForge project IDs
    if [[ "$cleaned" =~ ^[0-9]+$ ]]; then
        out_platform="curseforge"
        out_id="$cleaned"
        return 0
    fi

    # Raw Modrinth ID/slug
    if [[ "$cleaned" =~ ^[A-Za-z0-9_-]{3,}$ ]]; then
        out_platform="modrinth"
        out_id="$cleaned"
        return 0
    fi

    return 1
}

# find_existing_mod_index: Find existing mod index by platform and ID
# Parameters:
#   $1 - platform (modrinth/curseforge)
#   $2 - ID
# Returns: index on stdout or empty if not found
find_existing_mod_index() {
    local platform="$1"
    local mod_id="$2"
    local i
    for i in "${!MOD_IDS[@]}"; do
        if [[ "${MOD_TYPES[$i]}" == "$platform" && "${MOD_IDS[$i]}" == "$mod_id" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo ""
    return 1
}

# get_custom_mod_display_name: Resolve display name for custom mod
# Parameters:
#   $1 - platform
#   $2 - ID
# Returns: best-effort display name
get_custom_mod_display_name() {
    local platform="$1"
    local mod_id="$2"

    if [[ "$platform" == "modrinth" ]]; then
        local api_url="https://api.modrinth.com/v2/project/$mod_id"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -n "$tmp_file" ]]; then
            if command -v curl >/dev/null 2>&1; then
                curl -s -m 12 -o "$tmp_file" "$api_url" 2>/dev/null
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$tmp_file" --timeout=12 "$api_url" 2>/dev/null
            fi

            if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
                local title
                title=$(jq -r '.title // .name // empty' "$tmp_file" 2>/dev/null)
                rm -f "$tmp_file"
                if [[ -n "$title" && "$title" != "null" ]]; then
                    echo "$title"
                    return 0
                fi
            fi
            rm -f "$tmp_file"
        fi
        echo "Custom Modrinth mod ($mod_id)"
        return 0
    fi

    local api_token=""
    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -n "$api_token" ]]; then
        local cf_api_url="https://api.curseforge.com/v1/mods/$mod_id"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -n "$tmp_file" ]]; then
            if command -v curl >/dev/null 2>&1; then
                curl -s -m 12 -H "x-api-key: $api_token" -o "$tmp_file" "$cf_api_url" 2>/dev/null
            elif command -v wget >/dev/null 2>&1; then
                wget -q --timeout=12 --header="x-api-key: $api_token" -O "$tmp_file" "$cf_api_url" 2>/dev/null
            fi

            if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
                local name
                name=$(jq -r '.data.name // empty' "$tmp_file" 2>/dev/null)
                rm -f "$tmp_file"
                if [[ -n "$name" && "$name" != "null" ]]; then
                    echo "$name"
                    return 0
                fi
            fi
            rm -f "$tmp_file"
        fi
    fi

    echo "Custom CurseForge mod ($mod_id)"
    return 0
}

# print_supported_versions_for_custom_mod: Show compatible Fabric MC versions for a custom mod
# Parameters:
#   $1 - platform
#   $2 - ID
print_supported_versions_for_custom_mod() {
    local platform="$1"
    local mod_id="$2"

    print_info "Compatible Minecraft versions for this mod (Fabric):"

    if [[ "$platform" == "modrinth" ]]; then
        local api_url="https://api.modrinth.com/v2/project/$mod_id/version"
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -z "$tmp_file" ]]; then
            print_warning "Could not allocate temp file to query supported versions"
            return 1
        fi

        if command -v curl >/dev/null 2>&1; then
            curl -s -m 15 -o "$tmp_file" "$api_url" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$tmp_file" --timeout=15 "$api_url" 2>/dev/null
        fi

        if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
            local versions
            versions=$(jq -r '.[] | select(any(.loaders[]?; . == "fabric")) | .game_versions[]?' "$tmp_file" 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
                | sort -Vu \
                | tail -n 30)
            rm -f "$tmp_file"

            if [[ -n "$versions" ]]; then
                echo "$versions" | while IFS= read -r v; do
                    echo "  - $v"
                done
                return 0
            fi
        fi

        rm -f "$tmp_file"
        print_warning "Could not determine supported versions from Modrinth API"
        return 1
    fi

    local api_token=""
    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -z "$api_token" ]]; then
        print_warning "Could not access CurseForge API to list supported versions"
        return 1
    fi

    local cf_files_url="https://api.curseforge.com/v1/mods/$mod_id/files?modLoaderType=4"
    local tmp_file
    tmp_file=$(mktemp)
    if [[ -z "$tmp_file" ]]; then
        print_warning "Could not allocate temp file to query supported versions"
        return 1
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -s -m 15 -H "x-api-key: $api_token" -o "$tmp_file" "$cf_files_url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --header="x-api-key: $api_token" -O "$tmp_file" "$cf_files_url" 2>/dev/null
    fi

    if [[ -s "$tmp_file" ]] && command -v jq >/dev/null 2>&1; then
        local versions
        versions=$(jq -r '.data[]?.gameVersions[]?' "$tmp_file" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            | sort -Vu \
            | tail -n 30)
        rm -f "$tmp_file"

        if [[ -n "$versions" ]]; then
            echo "$versions" | while IFS= read -r v; do
                echo "  - $v"
            done
            return 0
        fi
    fi

    rm -f "$tmp_file"
    print_warning "Could not determine supported versions from CurseForge API"
    return 1
}

# check_modrinth_mod_strict: strict custom check (Fabric + exact MC version only)
check_modrinth_mod_strict() {
    local mod_name="$1"
    local mod_id="$2"
    local api_url="https://api.modrinth.com/v2/project/$mod_id/version"

    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for $mod_name"
        return 1
    fi

    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" "$api_url")
    local version_json
    version_json=$(cat "$tmp_body")
    rm -f "$tmp_body"

    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . >/dev/null 2>&1; then
        print_warning "❌ $mod_name ($mod_id) - API error"
        return 1
    fi

    local file_url=""
    local dep_ids=""
    CUSTOM_MOD_LAST_INCOMPAT_REASON=""
    file_url=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $v)) | .files[] | select(.primary == true) | .url' 2>/dev/null | head -n1)
    if [[ -n "$file_url" && "$file_url" != "null" ]]; then
        dep_ids=$(printf "%s" "$version_json" | jq -r --arg v "$MC_VERSION" '.[] | select((.loaders[]? == "fabric") and any(.game_versions[]?; . == $v)) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null | tr '\n' ' ')
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$mod_id")
        MOD_TYPES+=("modrinth")
        MOD_DEPENDENCIES+=("$dep_ids")
        print_success "✅ $mod_name (Modrinth)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON=""
        return 0
    fi

    local fabric_release_count=0
    fabric_release_count=$(printf "%s" "$version_json" | jq -r '[.[] | select(any(.loaders[]?; . == "fabric"))] | length' 2>/dev/null || echo "0")
    if [[ "$fabric_release_count" == "0" ]]; then
        print_warning "❌ $mod_name ($mod_id) - no Fabric versions found on Modrinth"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="no_fabric"
    else
        print_warning "❌ $mod_name ($mod_id) - no exact Fabric support for Minecraft $MC_VERSION"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="version_mismatch"
    fi
    return 1
}

# check_curseforge_mod_strict: strict custom check (Fabric + exact MC version only)
check_curseforge_mod_strict() {
    local mod_name="$1"
    local cf_project_id="$2"
    local api_token=""
    local file_url=""
    local dep_ids=""
    CUSTOM_MOD_LAST_INCOMPAT_REASON=""

    if ! api_token=$(get_curseforge_api_token 2>/dev/null); then
        api_token=""
    fi
    if [[ -z "$api_token" ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - unable to access CurseForge API token"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="api_error"
        return 1
    fi

    local cf_api_url="https://api.curseforge.com/v1/mods/$cf_project_id/files?modLoaderType=4"
    local tmp_body
    tmp_body=$(mktemp)
    if [[ -z "$tmp_body" ]]; then
        print_warning "mktemp failed for CurseForge API call"
        return 1
    fi

    local http_code
    http_code=$(curl -s -L -w "%{http_code}" -o "$tmp_body" -H "x-api-key: $api_token" "$cf_api_url" 2>/dev/null)
    local version_json
    version_json=$(cat "$tmp_body")
    rm -f "$tmp_body"

    if [[ "$http_code" != "200" ]] || ! printf "%s" "$version_json" | jq -e . >/dev/null 2>&1; then
        print_warning "❌ $mod_name ($cf_project_id) - API error (HTTP $http_code)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="api_error"
        return 1
    fi

    local jq_result
    jq_result=$(printf "%s" "$version_json" | jq -r --arg mc_version "$MC_VERSION" '
        .data[]
        | select(any(.gameVersions[]?; . == $mc_version))
        | {url: .downloadUrl, dependencies: (.dependencies // [] | map(select(.relationType == 3) | .modId))}
        | @base64' 2>/dev/null | head -n1)

    if [[ -n "$jq_result" ]]; then
        local decoded
        decoded=$(echo "$jq_result" | base64 --decode)
        file_url=$(echo "$decoded" | jq -r '.url')
        dep_ids=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
        SUPPORTED_MODS+=("$mod_name")
        MOD_DESCRIPTIONS+=("")
        MOD_URLS+=("$file_url")
        MOD_IDS+=("$cf_project_id")
        MOD_TYPES+=("curseforge")
        MOD_DEPENDENCIES+=("$dep_ids")
        print_success "✅ $mod_name (CurseForge)"
        CUSTOM_MOD_LAST_INCOMPAT_REASON=""
        return 0
    fi

    local fabric_file_count=0
    fabric_file_count=$(printf "%s" "$version_json" | jq -r '.data | length' 2>/dev/null || echo "0")
    if [[ "$fabric_file_count" == "0" ]]; then
        print_warning "❌ $mod_name ($cf_project_id) - no Fabric files found on CurseForge"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="no_fabric"
    else
        print_warning "❌ $mod_name ($cf_project_id) - no exact Fabric support for Minecraft $MC_VERSION"
        CUSTOM_MOD_LAST_INCOMPAT_REASON="version_mismatch"
    fi
    return 1
}

# prompt_custom_mods: Interactive flow for adding custom mods
# Parameters:
#   $1 - nameref to associative array tracking already-added indexes
prompt_custom_mods() {
    local -n added_map_ref="$1"

    echo ""
    print_warning "Custom mods are untested in this splitscreen setup. Add at your own risk."
    local add_custom_choice="n"
    if ! read -r -p "Do you want to add custom mods from Modrinth/CurseForge? (y/N): " add_custom_choice; then
        print_warning "No input available for custom mod prompt, skipping custom mods."
        return 0
    fi

    case "${add_custom_choice,,}" in
        y|yes) ;;
        *) return 0 ;;
    esac

    print_info "Add one mod at a time, then press Enter."
    print_info "CurseForge: paste just the numeric project ID (example: 422301)"
    print_info "Modrinth: paste the mod URL or slug (example: sodium)"
    print_info "Custom mods must support your exact selected Minecraft version on Fabric."
    print_info "Type 'done' when finished."

    while true; do
        local custom_input=""
        if ! read -r -p "Custom mod (or 'done'): " custom_input; then
            print_info "Input ended. Continuing without additional custom mods."
            break
        fi

        case "${custom_input,,}" in
            done|d|q|quit|exit) break ;;
        esac

        if [[ -z "$custom_input" ]]; then
            continue
        fi

        local platform=""
        local mod_id=""
        if ! parse_custom_mod_input "$custom_input" platform mod_id; then
            print_warning "Could not parse that mod input. Use a supported URL or ID format."
            continue
        fi

        local existing_idx=""
        existing_idx=$(find_existing_mod_index "$platform" "$mod_id" || true)
        if [[ -n "$existing_idx" ]]; then
            if [[ -z "${added_map_ref[$existing_idx]:-}" ]]; then
                FINAL_MOD_INDEXES+=("$existing_idx")
                added_map_ref[$existing_idx]=1
                add_mod_dependencies "$existing_idx" added_map_ref
            fi
            print_info "Already available, added to selection: ${SUPPORTED_MODS[$existing_idx]}"
            continue
        fi

        local display_name=""
        display_name=$(get_custom_mod_display_name "$platform" "$mod_id")
        local pre_count=${#SUPPORTED_MODS[@]}
        local compatible=false

        print_progress "Checking compatibility for custom mod: $display_name"
        if [[ "$platform" == "modrinth" ]]; then
            if check_modrinth_mod_strict "$display_name" "$mod_id"; then
                compatible=true
            fi
        else
            if check_curseforge_mod_strict "$display_name" "$mod_id"; then
                compatible=true
            fi
        fi

        if [[ "$compatible" == true ]]; then
            local new_idx=$(( ${#SUPPORTED_MODS[@]} - 1 ))
            if (( new_idx >= pre_count )); then
                FINAL_MOD_INDEXES+=("$new_idx")
                added_map_ref[$new_idx]=1
                add_mod_dependencies "$new_idx" added_map_ref
                print_success "Added custom mod: ${SUPPORTED_MODS[$new_idx]}"
            fi
            continue
        fi

        print_warning "Custom mod '$display_name' is not compatible with Minecraft $MC_VERSION (Fabric)."
        local incompatible_choice=""
        if [[ "${CUSTOM_MOD_LAST_INCOMPAT_REASON:-}" == "no_fabric" ]]; then
            echo "Options:"
            echo "  1. Continue without this mod (recommended)"
            echo "  2. Stop installer"
            if ! read -r -p "Choose [1]: " incompatible_choice; then
                incompatible_choice="1"
            fi
            case "$incompatible_choice" in
                2)
                    print_error "Installer stopped by user due to incompatible custom mod."
                    exit 1
                    ;;
                *)
                    print_info "Skipping incompatible custom mod."
                    ;;
            esac
            continue
        fi

        echo "Options:"
        echo "  1. Continue without this mod (recommended)"
        echo "  2. Change to a supported Minecraft version (core mods + this mod)"
        echo "  3. Stop installer"
        if ! read -r -p "Choose [1]: " incompatible_choice; then
            incompatible_choice="1"
        fi

        case "$incompatible_choice" in
            2)
                print_info "Switching to Minecraft version selection constrained by core mods and '$display_name'..."
                EXTRA_REQUIRED_MOD_ID="$mod_id"
                EXTRA_REQUIRED_MOD_PLATFORM="$platform"
                EXTRA_REQUIRED_MOD_NAME="$display_name"

                # Pre-check constrained versions so we can avoid confusing fallback errors.
                local -a constrained_versions=()
                readarray -t constrained_versions <<< "$(get_supported_minecraft_versions 2>/dev/null || true)"
                local -a constrained_clean=()
                local ver
                for ver in "${constrained_versions[@]}"; do
                    if [[ -n "$ver" && "$ver" != "null" ]]; then
                        constrained_clean+=("$ver")
                    fi
                done
                if [[ ${#constrained_clean[@]} -eq 0 ]]; then
                    print_warning "No compatible Minecraft versions found for core mods + '$display_name'."
                    print_info "Continuing without this custom mod."
                    unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME
                    continue
                fi

                # Re-run the version/core compatibility pipeline.
                if ! get_minecraft_version; then
                    print_warning "No compatible Minecraft versions found for core mods + '$display_name'."
                    print_info "Continuing without this custom mod."
                    unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME
                    continue
                fi
                detect_java
                configure_polymc_defaults
                get_fabric_version
                get_lwjgl_version

                # Reset runtime mod arrays and recompute compatibility for the new MC version.
                SUPPORTED_MODS=()
                MOD_DESCRIPTIONS=()
                MOD_URLS=()
                MOD_IDS=()
                MOD_TYPES=()
                MOD_DEPENDENCIES=()
                FINAL_MOD_INDEXES=()
                MISSING_MODS=()

                check_mod_compatibility

                # Clear version filter now that we've selected and refreshed.
                unset EXTRA_REQUIRED_MOD_ID EXTRA_REQUIRED_MOD_PLATFORM EXTRA_REQUIRED_MOD_NAME

                print_info "Minecraft version updated. Restarting mod selection..."
                select_user_mods
                return 2
                ;;
            3)
                print_error "Installer stopped by user due to incompatible custom mod."
                exit 1
                ;;
            *)
                print_info "Skipping incompatible custom mod."
                ;;
        esac
    done
}

# select_user_mods: Interactive mod selection with intelligent categorization
# Separates framework mods (auto-installed) from user-selectable mods
# Handles dependency resolution and ensures required splitscreen mods are included
select_user_mods() {
    print_header "🎯 MOD SELECTION"
    
    # Validate that we have compatible mods to present to the user
    local supported_count=0
    if [[ ${#SUPPORTED_MODS[@]} -gt 0 ]]; then
        supported_count=${#SUPPORTED_MODS[@]}
    fi
    if [[ $supported_count -eq 0 ]]; then
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
                    local max_range=${#user_mod_indexes[@]}
                    if ((start_num >= 1 && end_num <= max_range && start_num <= end_num)); then
                        for ((range_num=start_num; range_num<=end_num; range_num++)); do
                            expanded_selection+=("$range_num")
                        done
                    else
                        print_warning "Invalid range: $token (valid range: 1-$max_range)"
                    fi
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    # INDIVIDUAL NUMBER: Handle single number
                    local max_selection=${#user_mod_indexes[@]}
                    if ((token >= 1 && token <= max_selection)); then
                        expanded_selection+=("$token")
                    else
                        print_warning "Invalid selection: $token (valid range: 1-$max_selection)"
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

    # Optional user-provided custom mods (validated against selected MC version).
    local custom_prompt_status=0
    prompt_custom_mods added || custom_prompt_status=$?
    if [[ $custom_prompt_status -eq 2 ]]; then
        return 0
    fi

    # Automatically resolve all dependencies using Modrinth/CurseForge APIs
    # This replaces the manual dependency handling with full API-based resolution
    resolve_all_dependencies

    local final_count=0
    if [[ ${#FINAL_MOD_INDEXES[@]} -gt 0 ]]; then
        final_count=${#FINAL_MOD_INDEXES[@]}
    fi
    print_success "Final mod list prepared: $final_count mods selected"
}

# add_mod_dependencies: Add dependencies for a specific mod
add_mod_dependencies() {
    local mod_idx="$1"
    local -n added_ref="$2"
    
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
