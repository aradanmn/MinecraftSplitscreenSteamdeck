#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - Instance Creation Module
# =============================================================================
# 
# This module handles the creation of 4 separate Minecraft instances for splitscreen
# gameplay. Each instance is configured identically with mods but will be launched
# separately for multi-player splitscreen gaming.
#
# Functions provided:
# - create_instances: Main function to create 4 splitscreen instances
# - install_fabric_and_mods: Install Fabric loader and mods for an instance
#
# =============================================================================

# Per-instance JVM heap (MiB). Up to four instances run concurrently for 4-player
# splitscreen, so the TOTAL must fit alongside SteamOS + gamescope + nested KWin on
# a 16 GB Steam Deck. 4 × 3072 ≈ 12 GiB leaves headroom; the previous 4 × 4096 =
# 16 GiB would OOM at 3–4 players. Single/two-player sessions are unaffected (3 GiB
# is ample for vanilla + Sodium). Override via MCSS_MAX_MEM_MB / MCSS_MIN_MEM_MB.
: "${MCSS_MAX_MEM_MB:=3072}"
: "${MCSS_MIN_MEM_MB:=512}"

# write_mmc_pack_json: Write the PolyMC component stack for one instance.
# Fix #51 (D8): single writer — this heredoc was copy-pasted x3
# (create/install/update), a split-brain waiting to happen on upgrade.
# Component order matters: LWJGL3 → Minecraft → Intermediary Mappings →
# Fabric Loader.
# Inputs:
#   $1 — target path (…/mmc-pack.json)
#   Globals: MC_VERSION, LWJGL_VERSION, FABRIC_VERSION (read)
# Outputs:
#   return — 0 on success, non-zero if the write failed
write_mmc_pack_json() {
    local target_path="$1"
    cat > "$target_path" <<EOF
{
    "components": [
        {
            "cachedName": "LWJGL 3",
            "cachedVersion": "$LWJGL_VERSION",
            "cachedVolatile": true,
            "dependencyOnly": true,
            "uid": "org.lwjgl3",
            "version": "$LWJGL_VERSION"
        },
        {
            "cachedName": "Minecraft",
            "cachedRequires": [
                {
                    "suggests": "$LWJGL_VERSION",
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
}

# create_instances: Create 4 identical Minecraft instances for splitscreen play
# Uses manual instance creation for reliability
# Each instance gets the same mods but separate configurations for splitscreen
create_instances() {
    print_header "🚀 CREATING MINECRAFT INSTANCES"
    
    # Verify required variables are set
    if [[ -z "${MC_VERSION:-}" ]]; then
        print_error "MC_VERSION is not set. Cannot create instances."
        exit 1
    fi
    
    if [[ -z "${FABRIC_VERSION:-}" ]]; then
        print_error "FABRIC_VERSION is not set. Cannot create instances."
        exit 1
    fi
    
    print_info "Creating instances for Minecraft $MC_VERSION with Fabric $FABRIC_VERSION"
    
    # Clean up the final mod selection list (remove any duplicates from dependency resolution)
    FINAL_MOD_INDEXES=( $(printf "%s\n" "${FINAL_MOD_INDEXES[@]}" | sort -u) )
    
    # Initialize tracking for mods that fail to install
    MISSING_MODS=()
    
    # Ensure instances directory exists
    mkdir -p "$TARGET_DIR/instances"
    
    # Check if we're updating existing PolyMC instances.
    local existing_instances=0
    local instances_dir="$TARGET_DIR/instances"
    
    for i in $(seq 1 "$MCSS_MAX_PLAYERS"); do
        local instance_name="${MCSS_INSTANCE_PREFIX}$i"
        if [[ -d "$TARGET_DIR/instances/$instance_name" ]]; then
            existing_instances=$((existing_instances + 1))
        fi
    done
    
    if [[ $existing_instances -gt 0 ]]; then
        print_info "🔄 UPDATE MODE: Found $existing_instances existing instance(s)"
        print_debug "Mods will be updated to match the selected Minecraft version"
        print_debug "Existing options.txt settings will be preserved"
        print_debug "Instance configurations will be updated to new versions"
    else
        print_info "🆕 FRESH INSTALL: Creating new splitscreen instances"
    fi
    
    print_progress "Creating $MCSS_MAX_PLAYERS splitscreen instances..."

    # Create exactly MCSS_MAX_PLAYERS instances named ${MCSS_INSTANCE_PREFIX}1..N —
    # the naming convention the splitscreen launcher expects (paired constants:
    # installer entry ↔ runtime_context.sh).

    # Disable strict error handling for instance creation to prevent early exit
    print_debug "Starting instance creation with improved error handling"
    set +e  # Disable exit on error for this section

    for i in $(seq 1 "$MCSS_MAX_PLAYERS"); do
        local instance_name="${MCSS_INSTANCE_PREFIX}$i"
        local preserve_options_txt=false  # Reset for each instance
        print_progress "Creating instance $i of $MCSS_MAX_PLAYERS: $instance_name"
        
        # Check if this is an update scenario - look in the correct instances directory
        if [[ -d "$instances_dir/$instance_name" ]]; then
            preserve_options_txt=$(handle_instance_update "$instances_dir/$instance_name" "$instance_name")
        fi
        
        print_progress "Creating Minecraft $MC_VERSION instance with Fabric..."
        local instance_dir="$TARGET_DIR/instances/$instance_name"

        # Manual instance creation by writing PolyMC metadata files directly.
        mkdir -p "$instance_dir" || {
            print_error "Failed to create instance directory: $instance_dir"
            continue
        }

        mkdir -p "$instance_dir/.minecraft" || {
            print_error "Failed to create .minecraft directory in $instance_dir"
            continue
        }

        cat > "$instance_dir/instance.cfg" <<EOF
InstanceType=OneSix
iconKey=default
name=Player $i
OverrideCommands=false
OverrideConsole=false
OverrideGameTime=false
OverrideJavaArgs=false
OverrideJavaLocation=true
OverrideMCLaunchMethod=false
OverrideMemory=true
OverrideNativeWorkarounds=false
OverrideWindow=false
JavaPath=$JAVA_PATH
MinMemAlloc=${MCSS_MIN_MEM_MB}
MaxMemAlloc=${MCSS_MAX_MEM_MB}
IntendedVersion=$MC_VERSION
EOF

        if [[ $? -ne 0 ]]; then
            print_error "Failed to create instance.cfg for $instance_name"
            continue
        fi

        # Fix #51 (D8): single writer replaces the copy-pasted heredoc.
        if ! write_mmc_pack_json "$instance_dir/mmc-pack.json"; then
            print_error "Failed to create mmc-pack.json for $instance_name"
            continue
        fi

        print_success "Manual instance creation completed for $instance_name"
        
        # INSTANCE VERIFICATION: Ensure the instance directory was created successfully
        # This verification step prevents subsequent operations on non-existent instances
        local target_instance_dir="$TARGET_DIR/instances/$instance_name"
        # H12: do NOT re-declare preserve_options_txt=false here — it would discard the
        # value handle_instance_update set above (line ~80), so a normal-location update
        # always lost options.txt. Keep that value; the cross-location branch below may
        # still force it true.

        # For updates, check if we're working with an existing instance in a different location
        if [[ -d "$instances_dir/$instance_name" && "$instances_dir" != "$TARGET_DIR/instances" ]]; then
            target_instance_dir="$instances_dir/$instance_name"
            preserve_options_txt=true
            print_info "Using existing instance at: $target_instance_dir"
        elif [[ ! -d "$target_instance_dir" ]]; then
            print_error "Instance directory not found: $target_instance_dir"
            continue  # Skip to next instance if this one failed
        fi
        
        print_success "Instance created successfully: $instance_name"
        
        # FABRIC AND MOD INSTALLATION: Configure mod loader and install selected mods
        # This step adds Fabric loader support and downloads all compatible mods
        install_fabric_and_mods "$target_instance_dir" "$instance_name" "$preserve_options_txt"
    done
    
    # Re-enable strict error handling after instance creation
    set -e
    # Fix #86: log string uses $MCSS_MAX_PLAYERS, not a bare "4" (#86 item d).
    print_success "Instance creation completed - all \
$MCSS_MAX_PLAYERS instances created successfully"
}

# Install Fabric mod loader and download all selected mods for an instance
# This function ensures each instance has the proper mod loader and all compatible mods
# Parameters:
#   $1 - instance_dir: Path to the PolyMC instance directory
#   $2 - instance_name: Display name of the instance for logging
#   $3 - preserve_options: Whether to preserve existing options.txt (true/false)
install_fabric_and_mods() {
    local instance_dir="$1"
    local instance_name="$2"
    local preserve_options="${3:-false}"
    
    print_progress "Installing Fabric loader for mod support..."
    
    # Temporarily disable strict error handling to prevent exit on individual mod failures
    local original_error_setting=$-
    set +e
    
    local pack_json="$instance_dir/mmc-pack.json"
    
    # FABRIC LOADER INSTALLATION: Add Fabric to the component stack if not present
    # Fabric loader is required for all Fabric mods to function properly
    # We check if it's already installed to avoid duplicate entries
    if [[ ! -f "$pack_json" ]] || ! grep -q "net.fabricmc.fabric-loader" "$pack_json" 2>/dev/null; then
        print_progress "Adding Fabric loader to $instance_name..."
        
        # Fix #51 (D8): single writer replaces the copy-pasted heredoc.
        write_mmc_pack_json "$pack_json"
        print_success "Fabric loader v$FABRIC_VERSION installed"
    fi
    
    # MOD DOWNLOAD AND INSTALLATION: Download all selected mods to instance
    # Create the mods directory where Fabric will load .jar files from
    local mods_dir="$instance_dir/.minecraft/mods"
    mkdir -p "$mods_dir"
    
    # Extract instance number from name (e.g., latestUpdate-1 -> 1)
    local instance_num="${instance_name##*-}"
    
    if [[ "$instance_num" == "1" ]]; then
        print_info "Downloading mods for first instance..."
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
            local versions_url="${MODRINTH_API_BASE}/project/$mod_id/version"
            
            # Fix #51 (D14): fetch_url replaces the duplicated curl/wget
            # branches; the debug logging structure is kept.
            print_debug "Trying fetch_url for $mod_name"
            if fetch_url "$versions_url" "$temp_resolve_file" \
                2>/dev/null; then
                if [[ -s "$temp_resolve_file" ]]; then
                    resolve_data=$(cat "$temp_resolve_file")
                    local resolve_bytes
                    resolve_bytes=$(wc -c < "$temp_resolve_file")
                    print_debug "fetch_url succeeded, got $resolve_bytes bytes"
                else
                    print_debug "fetch_url returned empty file"
                fi
            else
                print_debug "fetch_url failed"
            fi
            
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                # #27: was a loose /tmp/mod_*_api_response.json per mod with nothing ever
                # clearing them, so they accumulated across every --debug install run
                # indefinitely. Keep the intentional debug output (that's the point of
                # --debug) but corral it into one dedicated directory, which
                # main_workflow.sh's --debug handling clears ONCE at the start of a run.
                local debug_dir="/tmp/mcss-debug-api"
                mkdir -p "$debug_dir" 2>/dev/null || true
                local debug_file="${debug_dir}/mod_${mod_name// /_}_${mod_id}_api_response.json"
                if [[ -n "$resolve_data" ]]; then
                    printf "%s" "$resolve_data" > "$debug_file"
                    print_debug "Saved resolver data for $mod_name to $debug_file"
                    print_debug "API URL: $versions_url"
                    print_debug "Data length: ${#resolve_data} characters"
                else
                    print_debug "No data received for $mod_name (ID: $mod_id)"
                    print_debug "API URL: $versions_url"
                    if [[ "$mod_name" == *"Collective"* || "$mod_id" == "e0M1UDsY" ]]; then
                        print_debug "Collective is commonly optional and can be skipped"
                    fi
                    touch "$debug_file"
                    print_debug "Empty debug file created at: $debug_file"
                fi
            fi

            if [[ -n "$resolve_data" && "$resolve_data" != "[]" && "$resolve_data" != *"\"error\""* ]]; then
                print_debug "Attempting URL resolution for $mod_name (MC: $MC_VERSION)"
                
                # Try exact version match first
                mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' 2>/dev/null | head -n1)
                print_debug "Exact version match result: ${mod_url:-'(empty)'}"
                
                # Try major.minor version if exact match failed  
                if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                    local mc_major_minor
                    mc_major_minor=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
                    print_debug "Trying major.minor version: $mc_major_minor"
                    
                    # Try exact major.minor
                    mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_major_minor" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' 2>/dev/null | head -n1)
                    print_debug "Major.minor match result: ${mod_url:-'(empty)'}"
                    
                    # Try wildcard version (e.g., "1.21.x")
                    if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                        local mc_major_minor_x="$mc_major_minor.x"
                        print_debug "Trying wildcard version: $mc_major_minor_x"
                        mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_major_minor_x" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' 2>/dev/null | head -n1)
                        print_debug "Wildcard match result: ${mod_url:-'(empty)'}"
                    fi
                    
                    # Try limited previous patch version (more restrictive than prefix matching)
                    if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                        local mc_patch_version
                        mc_patch_version=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+\.([0-9]+)' | grep -oE '[0-9]+$')
                        if [[ -n "$mc_patch_version" && $mc_patch_version -gt 0 ]]; then
                            # Try one patch version down (e.g., if looking for 1.21.6, try 1.21.5)
                            local prev_patch=$((mc_patch_version - 1))
                            local mc_prev_version="$mc_major_minor.$prev_patch"
                            print_debug "Trying limited backwards compatibility with: $mc_prev_version"
                            mod_url=$(printf "%s" "$resolve_data" | jq -r --arg v "$mc_prev_version" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' 2>/dev/null | head -n1)
                            print_debug "Limited backwards compatibility result: ${mod_url:-'(empty)'}"
                        fi
                    fi
                fi
                
                # If still no URL found, try the latest Fabric version for any compatible release
                if [[ -z "$mod_url" || "$mod_url" == "null" ]]; then
                    print_debug "Trying latest Fabric version (any compatible release)"
                    mod_url=$(printf "%s" "$resolve_data" | jq -r '.[] | select(.loaders[] == "fabric") | (.files | map(select(.primary)) | .[0].url) // (.files[0].url)' 2>/dev/null | head -n1)
                    print_debug "Latest Fabric match result: ${mod_url:-'(empty)'}"
                fi
                
                print_debug "Final URL for $mod_name: ${mod_url:-'(none found)'}"
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
            # Check if this is a critical required mod vs. optional dependency
            local is_required=false
            for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
                if [[ "$mod_name" == "$req"* ]]; then
                    is_required=true
                    break
                fi
            done
            
            if [[ "$is_required" == true ]]; then
                print_error "❌ CRITICAL: Required mod '$mod_name' could not be downloaded!"
                print_error "   This mod is essential for splitscreen functionality."
                print_info "   → However, continuing to create remaining instances..."
                print_info "   → You may need to manually install this mod later."
                MISSING_MODS+=("$mod_name")  # Track for final summary
                continue
            else
                print_warning "⚠️  Optional dependency '$mod_name' could not be downloaded."
                print_info "   → This is likely a dependency that doesn't support Minecraft $MC_VERSION"
                print_info "   → Continuing installation without this optional dependency"
                MISSING_MODS+=("$mod_name")  # Track for final summary
                continue
            fi
        fi
        
        # DOWNLOAD MOD FILE: Attempt to download the mod .jar file
        # N12: sanitize the WHOLE filename to [A-Za-z0-9._-] (not just spaces) so a mod
        # title containing '/' (or other separators) can't escape mods_dir
        # via the fetch_url output path.
        # Identical to the old space→underscore behavior for ordinary names.
        local safe_name="${mod_name//[^A-Za-z0-9._-]/_}"
        local mod_file="$mods_dir/${safe_name}.jar"
        # Fix #51 (D14): fetch_url replaces bare wget; timeout 0 — mod
        # jars are bulk artifacts and must not be cut off mid-download.
        if fetch_url "$mod_url" "$mod_file" 0 >/dev/null 2>&1; then
            print_success "Success: $mod_name"
        else
            print_warning "Failed: $mod_name"
            MISSING_MODS+=("$mod_name")  # Track download failures for summary
        fi
    done
    else
        # For instances 2-4, copy mods from instance 1
        print_info "Copying mods from instance 1 to $instance_name..."
        local instance1_mods_dir="$TARGET_DIR/instances/${MCSS_INSTANCE_PREFIX}1/.minecraft/mods"
        if [[ -d "$instance1_mods_dir" ]]; then
            # N13: without nullglob, an EMPTY instance1_mods_dir leaves the glob
            # unexpanded (the literal string ".../mods/*"), so `cp -r` fails with
            # "No such file or directory" and a legitimate empty mod set (zero
            # optional mods selected) gets reported as a copy FAILURE. Also, a single
            # unreadable file previously failed the WHOLE batched `cp -r *` — copy
            # file-by-file so one bad file doesn't mask the rest succeeding.
            shopt -s nullglob
            local -a _mod_src_files=("$instance1_mods_dir"/*)
            shopt -u nullglob
            if [[ ${#_mod_src_files[@]} -eq 0 ]]; then
                print_info "Instance 1 has no mods to copy (empty mod set) — nothing to do"
            else
                local _mod_copy_failed=0 _mod_src
                for _mod_src in "${_mod_src_files[@]}"; do
                    cp -r "$_mod_src" "$mods_dir/" 2>/dev/null || _mod_copy_failed=1
                done
                if [[ "$_mod_copy_failed" -eq 0 ]]; then
                    print_success "✅ Successfully copied mods from instance 1"
                else
                    print_warning "⚠️  Some mod(s) failed to copy from instance 1 (see above)"
                fi
            fi
        else
            print_error "Could not find mods directory from instance 1"
        fi
    fi
    
    # =============================================================================
    # MINECRAFT AUDIO CONFIGURATION
    # =============================================================================
    
    # SPLITSCREEN AUDIO SETUP: Configure audio volume for each instance
    # Instance 1 is the primary audio source; instances 2-4 previously only had MUSIC
    # muted, but all 4 JVMs share ONE PulseAudio sink and each independently renders
    # proximity-based ambient/environment sound for the SAME shared world (e.g. all 4
    # players standing near one creeper each trigger their own instance's hostile-mob
    # sound), so those categories still audibly overlapped/echoed 4x (#32/G7). Extend
    # the same "instance 1 is the one shared audio source" treatment to every
    # world-ambient category, while leaving `player` (each player's own action/hurt
    # feedback — a genuinely per-player, non-duplicated sound) audible on every instance.
    print_progress "Configuring splitscreen audio settings for $instance_name..."

    # Extract instance number from instance name (latestUpdate-X format)
    local instance_number
    instance_number=$(echo "$instance_name" | grep -oE '[0-9]+$')

    # Determine audio volumes based on instance number
    local music_volume="0.3" ambient_sfx_volume="1.0"  # Instance 1 defaults
    if [[ "$instance_number" -gt 1 ]]; then
        music_volume="0.0"        # Mute music for instances 2, 3, and 4
        ambient_sfx_volume="0.0"  # #32/G7: also mute shared-world ambient/env sound
        print_info "   → Music + ambient/environment sound muted for $instance_name (prevents audio overlap; per-player sounds stay audible)"
    else
        print_info "   → Music + ambient/environment sound enabled for $instance_name (primary audio instance)"
    fi
    
    # Create or update Minecraft options.txt file with splitscreen-optimized settings
    # This file contains all Minecraft client settings including audio, graphics, and controls
    local options_file="$instance_dir/.minecraft/options.txt"
    
    # Skip creating options.txt if we're preserving existing user settings
    if [[ "$preserve_options" == "true" ]] && [[ -f "$options_file" ]]; then
        print_info "   → Preserving existing options.txt settings"
    else
        print_info "   → Creating default splitscreen-optimized options.txt"
        mkdir -p "$(dirname "$options_file")"
        cat > "$options_file" <<EOF
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
soundCategory_record:${ambient_sfx_volume}
soundCategory_weather:${ambient_sfx_volume}
soundCategory_block:${ambient_sfx_volume}
soundCategory_hostile:${ambient_sfx_volume}
soundCategory_neutral:${ambient_sfx_volume}
soundCategory_player:1.0
soundCategory_ambient:${ambient_sfx_volume}
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
    fi
    
    print_success "Audio configuration complete for $instance_name"
    
    print_success "Fabric and mods installation complete for $instance_name"
    
    # Restore original error handling setting
    if [[ $original_error_setting == *e* ]]; then
        set -e
    fi
}

# handle_instance_update: Handle updating an existing instance
# This function is called when an existing instance is detected during installation
# It clears out old mods but preserves the user's options.txt configuration
# Parameters:
#   $1 - instance_dir: Path to the existing instance directory
#   $2 - instance_name: Display name of the instance for logging
handle_instance_update() {
    local instance_dir="$1"
    local instance_name="$2"
    
    print_info "🔄 Updating existing instance: $instance_name"
    print_info "   → This will update the instance to MC $MC_VERSION with Fabric $FABRIC_VERSION"
    print_info "   → Your existing settings and preferences will be preserved"
    
    # Check if there's a mods folder and clear it
    local mods_dir="$instance_dir/.minecraft/mods"
    if [[ -d "$mods_dir" ]]; then
        print_progress "Clearing old mods from $instance_name..."
        rm -rf "$mods_dir"
        print_success "✅ Old mods cleared"
    else
        print_info "ℹ️  No existing mods folder found - will create fresh mod installation"
    fi
    
    # Ensure .minecraft directory exists
    mkdir -p "$instance_dir/.minecraft"
    
    # Check if options.txt exists
    local options_file="$instance_dir/.minecraft/options.txt"
    if [[ -f "$options_file" ]]; then
        print_info "✅ Preserving existing options.txt (user settings will be kept)"
        # Create a backup of options.txt
        cp "$options_file" "${options_file}.backup"
    else
        print_info "ℹ️  No existing options.txt found - will create default splitscreen settings"
    fi
    
    # Update the instance configuration files to match the new version
    # This ensures the instance uses the correct Minecraft and Fabric versions
    print_progress "Updating instance configuration for MC $MC_VERSION with Fabric $FABRIC_VERSION..."
    
    # Update instance.cfg
    if [[ -f "$instance_dir/instance.cfg" ]]; then
        # Update the IntendedVersion line
        sed -i "s/^IntendedVersion=.*/IntendedVersion=$MC_VERSION/" "$instance_dir/instance.cfg"
        sed -i "s|^OverrideJavaLocation=.*|OverrideJavaLocation=true|" "$instance_dir/instance.cfg"
        sed -i "s|^OverrideMemory=.*|OverrideMemory=true|" "$instance_dir/instance.cfg"

        if grep -q "^JavaPath=" "$instance_dir/instance.cfg"; then
            sed -i "s|^JavaPath=.*|JavaPath=$JAVA_PATH|" "$instance_dir/instance.cfg"
        else
            echo "JavaPath=$JAVA_PATH" >> "$instance_dir/instance.cfg"
        fi

        if ! grep -q "^MinMemAlloc=" "$instance_dir/instance.cfg"; then
            echo "MinMemAlloc=${MCSS_MIN_MEM_MB}" >> "$instance_dir/instance.cfg"
        fi
        if ! grep -q "^MaxMemAlloc=" "$instance_dir/instance.cfg"; then
            echo "MaxMemAlloc=${MCSS_MAX_MEM_MB}" >> "$instance_dir/instance.cfg"
        fi
        print_success "✅ Instance configuration updated"
    fi
    
    # Perform fabric and mod installation, making sure to preserve options.txt
    install_fabric_and_mods "$instance_dir" "$instance_name" true
    
    # Restore options.txt if it was backed up
    if [[ -f "${options_file}.backup" ]]; then
        mv "${options_file}.backup" "$options_file"
        print_info "✅ Restored user's options.txt settings"
    fi
    
    # Update mmc-pack.json with new component versions.
    # Fix #51 (D8): single writer replaces the copy-pasted heredoc.
    write_mmc_pack_json "$instance_dir/mmc-pack.json"

    print_success "✅ Instance update preparation complete for $instance_name"
    print_info "   → Mods cleared and ready for new installation"
    print_info "   → User settings preserved"
    print_info "   → Version updated to MC $MC_VERSION with Fabric $FABRIC_VERSION"
    
    # Return true if we found and preserved an options.txt file
    if [[ -f "$options_file" ]]; then
        echo "true"
    else
        echo "false"
    fi
}
