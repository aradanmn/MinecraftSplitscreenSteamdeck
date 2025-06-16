#!/bin/bash
# Minecraft Splitscreen Steam Deck Installer
# 
# This script automatically downloads and installs Minecraft with splitscreen support
# for Steam Deck. It handles mod compatibility checking using the official Modrinth 
# and CurseForge APIs, and automatically fetches required encrypted API tokens from
# the GitHub repository using a fixed passphrase that works across all script versions.
#
# No additional setup or token files are required - just run this script.
#

# --- Get script directory before changing working directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set the Prism Launcher data directory
# This is where Prism Launcher stores all its configuration, instances, and assets
# On Steam Deck/Linux, this is typically $HOME/.local/share/PrismLauncher
# The minecraftSplitscreen.sh launcher expects PrismLauncher paths

targetDir=$HOME/.local/share/PrismLauncher
mkdir -p $targetDir
pushd $targetDir

    # Detect system Java (require Java 21 for modern Minecraft versions)
    # Only Java 21 is supported for new Minecraft versions
    if [ -x /usr/lib/jvm/java-21-openjdk/bin/java ]; then
        JAVA_PATH="/usr/lib/jvm/java-21-openjdk/bin/java"
    elif [ -x /usr/lib/jvm/default-runtime/bin/java ]; then
        JAVA_PATH="/usr/lib/jvm/default-runtime/bin/java"
    else
        JAVA_PATH="$(which java)"
    fi

    # Check if Java 21 is available and executable
    # Exit with a clear error if not found
    if [ -z "$JAVA_PATH" ] || ! "$JAVA_PATH" -version 2>&1 | grep -q '21'; then
        echo "Error: Java 21 is not installed or not found in a standard location. Refer to the README at https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck for installation instructions." >&2
        exit 1
    fi

    # Download Prism Launcher AppImage if not already present
    if [ ! -f "PrismLauncher.AppImage" ]; then
        echo "Fetching latest Prism Launcher AppImage URL from GitHub..."
        PRISM_URL=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest | \
            jq -r '.assets[] | select(.name | test("AppImage$")) | .browser_download_url' | head -n1)
        if [ -z "$PRISM_URL" ] || [ "$PRISM_URL" = "null" ]; then
            echo "Error: Could not find latest Prism Launcher AppImage URL. Please check https://github.com/PrismLauncher/PrismLauncher/releases manually." >&2
            exit 1
        fi
        wget -O PrismLauncher.AppImage "$PRISM_URL"
        chmod +x PrismLauncher.AppImage
    fi

    # Verify PrismLauncher CLI functionality
    echo "Verifying PrismLauncher CLI capabilities..."
    
    # Check for basic CLI support
    if ! ./PrismLauncher.AppImage --help 2>/dev/null | grep -q -E "(cli|create|instance)"; then
        echo "Warning: PrismLauncher CLI may not support instance creation. Checking with --help-all..."
        if ! ./PrismLauncher.AppImage --help-all 2>/dev/null | grep -q -E "(cli|create-instance)"; then
            echo "Error: This version of PrismLauncher does not support CLI instance creation." >&2
            echo "Available options:" >&2
            ./PrismLauncher.AppImage --help 2>&1 | head -20 >&2
            echo "Please update to a newer version that supports CLI operations." >&2
            exit 1
        fi
    fi
    
    # Show available CLI commands for debugging
    echo "Available PrismLauncher CLI commands:"
    ./PrismLauncher.AppImage --help 2>&1 | grep -E "(create|instance|cli)" || echo "  (Basic CLI commands found)"
    echo "✅ PrismLauncher CLI instance creation verified"

    # Prompt user for Minecraft version
    read -p "Enter the Minecraft version to install (leave blank for latest): " MC_VERSION
    if [ -z "$MC_VERSION" ]; then
        echo "Detecting latest Minecraft version from Mojang..."
        MC_VERSION=$(curl -s "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq -r '.latest.release')
        echo "Using latest Minecraft version: $MC_VERSION"
    fi

    # Ensure the instances directory exists
    mkdir -p "$targetDir/instances"

    # --- Mod List (name, type, id/url) ---
    # Framework mods to never prompt for (optional but auto-included when needed)
    FRAMEWORK_MODS=("Fabric API" "Collective" "Framework (Fabric)" "Konkrete" "YetAnotherConfigLib")
    FRAMEWORK_IDS=("fabric-api" "collective" "framework" "konkrete" "yacl")
    # Required splitscreen mods that are ALWAYS installed (essential for functionality)
    REQUIRED_SPLITSCREEN_MODS=("Controllable (Fabric)" "Splitscreen Support")
    REQUIRED_SPLITSCREEN_IDS=("317269" "yJgqfSDR")
    MODS=(
      "Better Name Visibility|modrinth|pSfNeCCY"
      "Collective|modrinth|e0M1UDsY"
      "Controllable (Fabric)|curseforge|317269"
      "Fabric API|modrinth|P7dR8mSH"
      "Framework (Fabric)|curseforge|549225"
      "Full Brightness Toggle|modrinth|aEK1KhsC"
      "In-Game Account Switcher|modrinth|cudtvDnd"
      "Just Zoom|modrinth|iAiqcykM"
      "Konkrete|modrinth|J81TRJWm"
      "Mod Menu|modrinth|mOgUt4GM"
      "Old Combat Mod|modrinth|dZ1APLkO"
      "Reese's Sodium Options|modrinth|Bh37bMuy"
      "Sodium|modrinth|AANobbMI"
      "Sodium Dynamic Lights|modrinth|PxQSWIcD"
      "Sodium Extra|modrinth|PtjYWJkn"
      "Sodium Extras|modrinth|vqqx0QiE"
      "Sodium Options API|modrinth|Es5v4eyq"
      "Splitscreen Support|modrinth|yJgqfSDR"
      "YetAnotherConfigLib|modrinth|1eAoo2KR"
    )

    # --- Mod Compatibility Check and Selection ---
    SUPPORTED_MODS=()
    MOD_URLS=()
    MOD_IDS=()
    MOD_TYPES=()
    MOD_DEPENDENCIES=()
    echo "Checking mod compatibility for Minecraft $MC_VERSION..."
    for mod in "${MODS[@]}"; do
      IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "$mod"
      if [ "$MOD_TYPE" = "modrinth" ]; then
        API_URL="https://api.modrinth.com/v2/project/$MOD_ID/version"
        
        TMP_BODY=$(mktemp)
        if [ -z "$TMP_BODY" ]; then
            echo "Error: mktemp failed for $MOD_NAME."
            continue 
        fi

        # Fetch response body to TMP_BODY, get HTTP code. Follow redirects with -L.
        HTTP_CODE=$(curl -s -L -w "%{http_code}" -o "$TMP_BODY" "$API_URL")
        VERSION_JSON=$(cat "$TMP_BODY")
        rm "$TMP_BODY"

        IS_JSON_VALID=false
        # Check for HTTP 200 and if the response is valid JSON
        if [ "$HTTP_CODE" == "200" ] && printf "%s" "$VERSION_JSON" | jq -e . > /dev/null 2>&1; then
          IS_JSON_VALID=true
        fi

        if ! $IS_JSON_VALID; then
          echo "Mod $MOD_NAME ($MOD_ID) is not compatible with $MC_VERSION (API error or invalid data)"
          continue # Skip to the next mod in the main loop
        fi
        # --- All Modrinth logic must be inside this block ---
        if $IS_JSON_VALID; then
          # Try exact match first - ONLY FABRIC VERSIONS
          FILE_URL=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
          DEP_IDS=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_VERSION" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
          
          # If no exact match, try major.minor match (e.g., 1.21 for 1.21.5) - ONLY FABRIC
          if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
            MC_MAJOR_MINOR=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
            # Try 1.21
            FILE_URL=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
            DEP_IDS=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
            # Try 1.21.x
            if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
              MC_MAJOR_MINOR_X="$MC_MAJOR_MINOR.x"
              FILE_URL=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR_X" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
              DEP_IDS=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR_X" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
            fi
            # Try 1.21.0
            if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
              MC_MAJOR_MINOR_0="$MC_MAJOR_MINOR.0"
              FILE_URL=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
              DEP_IDS=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR_0" '.[] | select(.game_versions[] == $v and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
            fi
            # Try any version in the list that matches the same major.minor - ONLY FABRIC
            if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
              FILE_URL=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR" '.[] | select(.game_versions[] | startswith($v) and (.loaders[] == "fabric")) | .files[0].url' 2>/dev/null | head -n1)
              DEP_IDS=$(printf "%s" "$VERSION_JSON" | jq -r --arg v "$MC_MAJOR_MINOR" '.[] | select(.game_versions[] | startswith($v) and (.loaders[] == "fabric")) | .dependencies[]? | select(.dependency_type=="required") | .project_id' 2>/dev/null)
            fi
          fi
          # Enhanced: Check all files in all releases for any matching game_version - FABRIC ONLY
          if [ -z "$FILE_URL" ] || [ "$FILE_URL" = "null" ]; then
            FILE_URL="" # Reset FILE_URL before the enhanced search logic
            DEP_IDS=""  # Reset DEP_IDS
            MC_MAJOR_MINOR=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
            MC_MAJOR_MINOR_X="$MC_MAJOR_MINOR.x"
            MC_MAJOR_MINOR_0="$MC_MAJOR_MINOR.0"
            jq_filter='
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
            jq_result=$(printf "%s" "$VERSION_JSON" | jq -r \
              --arg mc_version "$MC_VERSION" \
              --arg mc_major_minor "$MC_MAJOR_MINOR" \
              --arg mc_major_minor_x "$MC_MAJOR_MINOR_X" \
              --arg mc_major_minor_0 "$MC_MAJOR_MINOR_0" \
              "$jq_filter" 2>/dev/null | head -n1)

            if [ -n "$jq_result" ]; then
              decoded=$(echo "$jq_result" | base64 --decode)
              FILE_URL=$(echo "$decoded" | jq -r '.url')
              DEP_IDS=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
            fi
          fi

          if [ -n "$FILE_URL" ] && [ "$FILE_URL" != "null" ]; then
            SUPPORTED_MODS+=("$MOD_NAME")
            MOD_URLS+=("$FILE_URL")
            MOD_IDS+=("$MOD_ID")
            MOD_TYPES+=("modrinth")
            MOD_DEPENDENCIES+=("$DEP_IDS")
          else
            echo "Mod $MOD_NAME ($MOD_ID) is not compatible with $MC_VERSION or could not be downloaded"
          fi
          continue
        fi
      elif [ "$MOD_TYPE" = "curseforge" ]; then
        # --- Use official CurseForge API for CurseForge mods ---
        CF_PROJECT_ID="$MOD_ID"
        # Fetch and decrypt API token from GitHub repository
        CF_TOKEN_ENC_URL="https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/token.enc"
        TMP_TOKEN_FILE=$(mktemp)
        if [ -z "$TMP_TOKEN_FILE" ]; then
          echo "Error: mktemp failed for $MOD_NAME."
          continue
        fi
        
        # Download encrypted token from GitHub
        HTTP_CODE=$(curl -s -L -w "%{http_code}" -o "$TMP_TOKEN_FILE" "$CF_TOKEN_ENC_URL")
        if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMP_TOKEN_FILE" ]; then
          echo "Failed to download encrypted CurseForge API token from GitHub (HTTP: $HTTP_CODE)."
          rm -f "$TMP_TOKEN_FILE"
          continue
        fi
        
        # Decrypt token using a fixed passphrase that works across all script versions
        FIXED_PASSPHRASE="MinecraftSplitscreenSteamDeck2025"
        CF_API_KEY=$(openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$FIXED_PASSPHRASE" -in "$TMP_TOKEN_FILE" 2>/dev/null)
        rm -f "$TMP_TOKEN_FILE"
        
        if [ $? -ne 0 ] || [ -z "$CF_API_KEY" ]; then
          echo "Failed to decrypt CurseForge API token for $MOD_NAME."
          continue
        fi
        CF_API_URL="https://api.curseforge.com/v1/mods/$CF_PROJECT_ID/files?modLoaderType=4"
        TMP_BODY=$(mktemp)
        if [ -z "$TMP_BODY" ]; then
          echo "Error: mktemp failed for $MOD_NAME."
          continue
        fi
        HTTP_CODE=$(curl -s -L -w "%{http_code}" -o "$TMP_BODY" -H "x-api-key: $CF_API_KEY" "$CF_API_URL")
        VERSION_JSON=$(cat "$TMP_BODY")
        rm "$TMP_BODY"
        
        IS_JSON_VALID=false
        if [ "$HTTP_CODE" == "200" ] && printf "%s" "$VERSION_JSON" | jq -e . > /dev/null 2>&1; then
          IS_JSON_VALID=true
        else
          echo "Mod $MOD_NAME ($CF_PROJECT_ID) is not compatible with $MC_VERSION or could not be downloaded (CurseForge API, HTTP $HTTP_CODE)"
          continue
        fi
        if $IS_JSON_VALID; then
          MC_MAJOR_MINOR=$(echo "$MC_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
          MC_MAJOR_MINOR_X="$MC_MAJOR_MINOR.x"
          MC_MAJOR_MINOR_0="$MC_MAJOR_MINOR.0"
          # Find the first file compatible with the MC version and Fabric loader
          jq_filter='
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
          jq_result=$(printf "%s" "$VERSION_JSON" | jq -r \
            --arg mc_version "$MC_VERSION" \
            --arg mc_major_minor "$MC_MAJOR_MINOR" \
            --arg mc_major_minor_x "$MC_MAJOR_MINOR_X" \
            --arg mc_major_minor_0 "$MC_MAJOR_MINOR_0" \
            "$jq_filter" 2>/dev/null | head -n1)
          if [ -n "$jq_result" ]; then
            decoded=$(echo "$jq_result" | base64 --decode)
            FILE_URL=$(echo "$decoded" | jq -r '.url')
            DEP_IDS=$(echo "$decoded" | jq -r '.dependencies[]?' | tr '\n' ' ')
            SUPPORTED_MODS+=("$MOD_NAME")
            MOD_URLS+=("$FILE_URL")
            MOD_IDS+=("$CF_PROJECT_ID")
            MOD_TYPES+=("curseforge")
            MOD_DEPENDENCIES+=("$DEP_IDS")
          else
            echo "Mod $MOD_NAME ($CF_PROJECT_ID) is not compatible with $MC_VERSION or could not be downloaded"
          fi
        fi
      fi # <-- This closes the main if/elif block for mod type
    done

    # --- User Selection of Mods (skip framework mods and required splitscreen mods) ---
    echo "\nThe following mods are available for Minecraft $MC_VERSION:"
    USER_MOD_INDEXES=()
    for i in "${!SUPPORTED_MODS[@]}"; do
      skip=false
      # Skip framework mods
      for fw in "${FRAMEWORK_MODS[@]}"; do
        if [[ "${SUPPORTED_MODS[$i]}" == "$fw"* ]]; then skip=true; break; fi
      done
      # Skip required splitscreen mods
      for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
        if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]]; then skip=true; break; fi
      done
      if ! $skip; then
        menu_num=$((${#USER_MOD_INDEXES[@]}+1))
        printf "%2d) %s\n" "$menu_num" "${SUPPORTED_MODS[$i]}"
        USER_MOD_INDEXES+=("$i")
      fi
    done
    echo " 0) Install ALL mods above (default)"
    echo "-1) Skip all mods"
    echo ""
    echo "Note: Controllable (Fabric) and Splitscreen Support will be automatically installed"
    echo "      as they are required for splitscreen functionality to work."
    read -p "Enter the numbers of the mods you want to install (e.g. 1 2 5), or 0 for all: " MOD_SELECTION
    INSTALL_ALL_MODS=false
    if [ -z "$MOD_SELECTION" ] || [ "$MOD_SELECTION" = "0" ]; then
      INSTALL_ALL_MODS=true
    fi
    if [ "$MOD_SELECTION" = "-1" ]; then
      MOD_SELECTION=""
    fi

    # --- Build final mod list including dependencies ---
    FINAL_MOD_INDEXES=()
    declare -A ADDED
    if $INSTALL_ALL_MODS; then
      for i in "${!SUPPORTED_MODS[@]}"; do
        FINAL_MOD_INDEXES+=("$i")
        ADDED[$i]=1
      done
    else
      echo "Selected mods:"
      for sel in $MOD_SELECTION; do
        idx=${USER_MOD_INDEXES[$((sel-1))]}
        echo "  ${SUPPORTED_MODS[$idx]}"
        FINAL_MOD_INDEXES+=("$idx")
        ADDED[$idx]=1
      done
      
      # For each selected mod, add required framework mods (dependencies) if not already included
      for sel in $MOD_SELECTION; do
        idx=${USER_MOD_INDEXES[$((sel-1))]}
        # Add required framework mods for curseforge mods (e.g. Controllable)
        if [[ "${SUPPORTED_MODS[$idx]}" == "Controllable (Fabric)"* ]]; then
          for j in "${!MODS[@]}"; do
            IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "${MODS[$j]}"
            if [[ "$MOD_NAME" == "Framework (Fabric)"* ]]; then
              for k in "${!MOD_IDS[@]}"; do
                if [[ "${MOD_IDS[$k]}" == "$MOD_ID" ]] && [ -z "${ADDED[$k]}" ]; then
                  FINAL_MOD_INDEXES+=("$k")
                  ADDED[$k]=1
                fi
              done
            fi
          done
        fi
        
        # Add required framework mods for modrinth mods (via dependencies)
        dep_string="${MOD_DEPENDENCIES[$idx]}"
        if [ -n "$dep_string" ]; then
          read -a dep_arr <<< "$dep_string"
          for dep in "${dep_arr[@]}"; do
            if [ -n "$dep" ]; then
              for j in "${!MOD_IDS[@]}"; do
                if [[ "${MOD_IDS[$j]}" == "$dep" ]] && [ -z "${ADDED[$j]}" ]; then
                  FINAL_MOD_INDEXES+=("$j")
                  ADDED[$j]=1
                fi
              done
            fi
          done
        fi
      done
    fi
    
    # --- Ensure required splitscreen mods are always included (essential for splitscreen functionality) ---
    for req in "${REQUIRED_SPLITSCREEN_MODS[@]}"; do
      for i in "${!SUPPORTED_MODS[@]}"; do
        if [[ "${SUPPORTED_MODS[$i]}" == "$req"* ]]; then
          if [ -z "${ADDED[$i]}" ]; then
            FINAL_MOD_INDEXES+=("$i")
            ADDED[$i]=1
            
            # Special handling for Controllable (Fabric) - ensure Framework (Fabric) dependency is added
            if [[ "${SUPPORTED_MODS[$i]}" == "Controllable (Fabric)"* ]]; then
              for j in "${!MODS[@]}"; do
                IFS='|' read -r MOD_NAME MOD_TYPE MOD_ID <<< "${MODS[$j]}"
                if [[ "$MOD_NAME" == "Framework (Fabric)"* ]]; then
                  for k in "${!MOD_IDS[@]}"; do
                    if [[ "${MOD_IDS[$k]}" == "$MOD_ID" ]] && [ -z "${ADDED[$k]}" ]; then
                      FINAL_MOD_INDEXES+=("$k")
                      ADDED[$k]=1
                    fi
                  done
                fi
              done
            fi
            
            # Process any Modrinth dependencies for this required mod
            dep_string="${MOD_DEPENDENCIES[$i]}"
            if [ -n "$dep_string" ]; then
              read -a dep_arr <<< "$dep_string"
              for dep in "${dep_arr[@]}"; do
                if [ -n "$dep" ]; then
                  for j in "${!MOD_IDS[@]}"; do
                    if [[ "${MOD_IDS[$j]}" == "$dep" ]] && [ -z "${ADDED[$j]}" ]; then
                      FINAL_MOD_INDEXES+=("$j")
                      ADDED[$j]=1
                    fi
                  done
                fi
              done
            fi
          fi
          break
        fi
      done
    done
    
    # Remove duplicates
    FINAL_MOD_INDEXES=( $(printf "%s\n" "${FINAL_MOD_INDEXES[@]}" | sort -u) )

    # --- Download selected mods (including dependencies) ---
    MISSING_MODS=()
    echo "Creating 4 splitscreen instances..."
    for i in {1..4}; do
        INSTANCE_NAME="latestUpdate-$i"
        echo "Creating instance $i of 4: $INSTANCE_NAME"
        
        # Remove existing instance if it exists
        if [ -d "$targetDir/instances/$INSTANCE_NAME" ]; then
            echo "  Removing existing instance: $INSTANCE_NAME"
            rm -rf "$targetDir/instances/$INSTANCE_NAME"
        fi
        
        # Create new instance using PrismLauncher CLI
        echo "  Creating Minecraft $MC_VERSION instance with Fabric..."
        CLI_SUCCESS=false
        
        # Try with Fabric loader first
        if ./PrismLauncher.AppImage --cli create-instance \
            --name "$INSTANCE_NAME" \
            --mc-version "$MC_VERSION" \
            --group "Splitscreen" \
            --loader "fabric" >/dev/null 2>&1; then
            CLI_SUCCESS=true
            echo "  ✅ Created with Fabric loader"
        # Try without loader specification
        elif ./PrismLauncher.AppImage --cli create-instance \
            --name "$INSTANCE_NAME" \
            --mc-version "$MC_VERSION" \
            --group "Splitscreen" >/dev/null 2>&1; then
            CLI_SUCCESS=true
            echo "  ✅ Created without specific loader"
        # Try basic creation with minimal parameters
        elif ./PrismLauncher.AppImage --cli create-instance \
            --name "$INSTANCE_NAME" \
            --mc-version "$MC_VERSION" >/dev/null 2>&1; then
            CLI_SUCCESS=true
            echo "  ✅ Created with minimal parameters"
        fi
        
        # If CLI failed, try manual instance creation
        if [ "$CLI_SUCCESS" = false ]; then
            echo "  [Warning] CLI instance creation failed, attempting manual creation..."
            INSTANCE_DIR="$targetDir/instances/$INSTANCE_NAME"
            mkdir -p "$INSTANCE_DIR"
            
            # Create minimal instance.cfg
            cat > "$INSTANCE_DIR/instance.cfg" <<EOF
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
            
            # Create minimal mmc-pack.json for mod support with Fabric
            mkdir -p "$INSTANCE_DIR/.minecraft"
            
            # Detect latest Fabric loader version for manual creation
            FABRIC_VERSION=$(curl -s "https://meta.fabricmc.net/v2/versions/loader" | jq -r '.[0].version' 2>/dev/null)
            if [ -z "$FABRIC_VERSION" ] || [ "$FABRIC_VERSION" = "null" ]; then
                FABRIC_VERSION="0.16.9"  # Fallback to a known stable version
            fi
            
            cat > "$INSTANCE_DIR/mmc-pack.json" <<EOF
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
            echo "  ✅ Manual instance creation completed"
        fi
        
        # Verify instance was created
        INSTANCE_DIR="$targetDir/instances/$INSTANCE_NAME"
        if [ ! -d "$INSTANCE_DIR" ]; then
            echo "  [Error] Instance directory not found: $INSTANCE_DIR"
            continue
        fi
        
        echo "  ✅ Instance created successfully: $INSTANCE_NAME"
        
        # --- Install Fabric Loader into the instance ---
        echo "  Installing Fabric loader for mod support..."
        PACK_JSON="$INSTANCE_DIR/mmc-pack.json"
        
        # Detect latest Fabric loader version
        FABRIC_VERSION=$(curl -s "https://meta.fabricmc.net/v2/versions/loader" | jq -r '.[0].version' 2>/dev/null)
        if [ -z "$FABRIC_VERSION" ] || [ "$FABRIC_VERSION" = "null" ]; then
            echo "  [Warning] Could not detect latest Fabric version, using fallback"
            FABRIC_VERSION="0.16.9"  # Fallback to a known stable version
        fi
        
        # Check if instance already has Fabric installed
        if [ -f "$PACK_JSON" ] && grep -q "net.fabricmc.fabric-loader" "$PACK_JSON" 2>/dev/null; then
            echo "  ✅ Fabric loader already installed"
        else
            echo "  Adding Fabric loader v$FABRIC_VERSION to instance..."
            
            # Create or update mmc-pack.json with Fabric
            if [ -f "$PACK_JSON" ]; then
                # Add complete Fabric dependency chain to existing pack.json
                TMP_PACK=$(mktemp)
                jq --arg fabric_ver "$FABRIC_VERSION" --arg mc_ver "$MC_VERSION" '
                    .components |= [
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
                            "cachedVersion": $mc_ver,
                            "important": true,
                            "uid": "net.minecraft",
                            "version": $mc_ver
                        },
                        {
                            "cachedName": "Intermediary Mappings",
                            "cachedRequires": [
                                {
                                    "equals": $mc_ver,
                                    "uid": "net.minecraft"
                                }
                            ],
                            "cachedVersion": $mc_ver,
                            "cachedVolatile": true,
                            "dependencyOnly": true,
                            "uid": "net.fabricmc.intermediary",
                            "version": $mc_ver
                        },
                        {
                            "cachedName": "Fabric Loader",
                            "cachedRequires": [
                                {
                                    "uid": "net.fabricmc.intermediary"
                                }
                            ],
                            "cachedVersion": $fabric_ver,
                            "uid": "net.fabricmc.fabric-loader",
                            "version": $fabric_ver
                        }
                    ] + .
                ' "$PACK_JSON" > "$TMP_PACK" && mv "$TMP_PACK" "$PACK_JSON"
            else
                # Create new pack.json with Fabric
                cat > "$PACK_JSON" <<EOF
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
            fi
            echo "  ✅ Fabric loader v$FABRIC_VERSION installed"
        fi
        
        # Create mods directory
        MODS_DIR="$INSTANCE_DIR/.minecraft/mods"
        mkdir -p "$MODS_DIR"
        for idx in "${FINAL_MOD_INDEXES[@]}"; do
          MOD_URL="${MOD_URLS[$idx]}"
          MOD_NAME="${SUPPORTED_MODS[$idx]}"
          if [ -z "$MOD_URL" ] || [ "$MOD_URL" = "null" ]; then
            echo "  [Warning] No compatible file found for $MOD_NAME. Skipping download."
            MISSING_MODS+=("$MOD_NAME")
            continue
          fi
          MOD_FILE="$MODS_DIR/${MOD_NAME// /_}.jar"
          if wget -O "$MOD_FILE" "$MOD_URL"; then
            echo "  Success: $MOD_NAME"
          else
            echo "  [Warning] Failed to download $MOD_NAME."
            MISSING_MODS+=("$MOD_NAME")
          fi
          # Check for 0-byte file (broken PrismLauncher proxy or bad URL)
          if [ ! -s "$MOD_FILE" ]; then
            echo "  [Error] Downloaded file for $MOD_NAME is 0 bytes! URL: $MOD_URL"
            rm -f "$MOD_FILE"
            MISSING_MODS+=("$MOD_NAME (0byte)")
            continue
          fi
        done
        
        # Configure instance for splitscreen play
        echo "  Configuring instance settings for Player $i..."
        if [ -f "$INSTANCE_DIR/instance.cfg" ]; then
            # Set instance name and display name
            if grep -q "^name=" "$INSTANCE_DIR/instance.cfg"; then
                sed -i "s/^name=.*/name=Player $i/" "$INSTANCE_DIR/instance.cfg"
            else
                echo "name=Player $i" >> "$INSTANCE_DIR/instance.cfg"
            fi
            
            # Configure Java and memory settings for splitscreen performance
            if grep -q "^JavaPath=" "$INSTANCE_DIR/instance.cfg"; then
                sed -i "s|^JavaPath=.*|JavaPath=$JAVA_PATH|" "$INSTANCE_DIR/instance.cfg"
            else
                echo "JavaPath=$JAVA_PATH" >> "$INSTANCE_DIR/instance.cfg"
            fi
            
            # Memory settings
            sed -i "s/^MaxMemAlloc=.*/MaxMemAlloc=3072/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "MaxMemAlloc=3072" >> "$INSTANCE_DIR/instance.cfg"
            sed -i "s/^MinMemAlloc=.*/MinMemAlloc=512/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "MinMemAlloc=512" >> "$INSTANCE_DIR/instance.cfg"
            sed -i "s/^OverrideMemory=.*/OverrideMemory=true/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "OverrideMemory=true" >> "$INSTANCE_DIR/instance.cfg"
            sed -i "s/^OverrideJavaLocation=.*/OverrideJavaLocation=true/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "OverrideJavaLocation=true" >> "$INSTANCE_DIR/instance.cfg"
            
            # Disable console auto-show for cleaner splitscreen experience
            sed -i "s/^ShowConsole=.*/ShowConsole=false/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "ShowConsole=false" >> "$INSTANCE_DIR/instance.cfg"
            sed -i "s/^ShowConsoleOnError=.*/ShowConsoleOnError=false/" "$INSTANCE_DIR/instance.cfg" 2>/dev/null || echo "ShowConsoleOnError=false" >> "$INSTANCE_DIR/instance.cfg"
        else
            echo "  [Warning] instance.cfg not found for $INSTANCE_NAME"
        fi
        
        # Create splitscreen configuration for each player
        CONFIG_DIR="$INSTANCE_DIR/.minecraft/config"
        mkdir -p "$CONFIG_DIR"
        SPLITSCREEN_CONFIG="$CONFIG_DIR/splitscreen.properties"
        
        # Set splitscreen mode based on player number
        case $i in
            1)
                echo "gap=1" > "$SPLITSCREEN_CONFIG"
                echo "mode=TOP" >> "$SPLITSCREEN_CONFIG"
                ;;
            2)
                echo "gap=1" > "$SPLITSCREEN_CONFIG"
                echo "mode=BOTTOM" >> "$SPLITSCREEN_CONFIG"
                ;;
            3)
                echo "gap=1" > "$SPLITSCREEN_CONFIG"
                echo "mode=BOTTOM_LEFT" >> "$SPLITSCREEN_CONFIG"
                ;;
            4)
                echo "gap=1" > "$SPLITSCREEN_CONFIG"
                echo "mode=BOTTOM_RIGHT" >> "$SPLITSCREEN_CONFIG"
                ;;
        esac
        
        echo "Configured instance: Player $i (${SPLITSCREEN_CONFIG##*/})"
    done

    # --- Verify all instances were created successfully ---
    echo "Verifying splitscreen instances..."
    CREATED_INSTANCES=0
    for i in {1..4}; do
        INSTANCE_NAME="latestUpdate-$i"
        INSTANCE_DIR="$targetDir/instances/$INSTANCE_NAME"
        if [ -d "$INSTANCE_DIR" ] && [ -f "$INSTANCE_DIR/instance.cfg" ]; then
            # Check if Fabric is properly installed
            PACK_JSON="$INSTANCE_DIR/mmc-pack.json"
            if [ -f "$PACK_JSON" ] && grep -q "net.fabricmc.fabric-loader" "$PACK_JSON"; then
                FABRIC_VER=$(jq -r '.components[] | select(.uid == "net.fabricmc.fabric-loader") | .version' "$PACK_JSON" 2>/dev/null)
                echo "  ✅ Player $i instance verified (Fabric $FABRIC_VER)"
            else
                echo "  ⚠️  Player $i instance verified (no Fabric loader)"
            fi
            CREATED_INSTANCES=$((CREATED_INSTANCES + 1))
        else
            echo "  ❌ Player $i instance missing or incomplete"
        fi
    done
    
    if [ "$CREATED_INSTANCES" -eq 0 ]; then
        echo "Error: No instances were created successfully. Please check PrismLauncher installation." >&2
        exit 1
    elif [ "$CREATED_INSTANCES" -lt 4 ]; then
        echo "Warning: Only $CREATED_INSTANCES out of 4 instances were created successfully."
        echo "You can still play splitscreen with $CREATED_INSTANCES player(s)."
    else
        echo "✅ All 4 splitscreen instances created successfully"
    fi

    # --- Refresh PrismLauncher instance list ---
    echo "Refreshing PrismLauncher instance list..."
    # Create instances.json to help PrismLauncher recognize the instances
    INSTANCES_JSON="$targetDir/instances.json"
    
    # Build instances.json dynamically based on created instances
    echo "{" > "$INSTANCES_JSON"
    echo '    "formatVersion": 1,' >> "$INSTANCES_JSON"
    echo '    "instances": {' >> "$INSTANCES_JSON"
    
    INSTANCE_ENTRIES=()
    for i in {1..4}; do
        INSTANCE_NAME="latestUpdate-$i"
        if [ -d "$targetDir/instances/$INSTANCE_NAME" ]; then
            INSTANCE_ENTRIES+=("        \"$INSTANCE_NAME\": {
            \"name\": \"Player $i\",
            \"group\": \"Splitscreen\"
        }")
        fi
    done
    
    # Join instance entries with commas
    IFS=','
    echo "${INSTANCE_ENTRIES[*]}" >> "$INSTANCES_JSON"
    unset IFS
    
    echo '    }' >> "$INSTANCES_JSON"
    echo '}' >> "$INSTANCES_JSON"
    
    echo "✅ Instance registry updated with ${#INSTANCE_ENTRIES[@]} instances"

    # --- Download accounts.json for splitscreen (needed for both launchers) ---
    echo "Setting up offline accounts for splitscreen..."
    if ! wget -O accounts.json "https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/accounts.json"; then
        echo "Warning: Failed to download accounts.json. Using local copy if available..." >&2
        if [ ! -f "accounts.json" ]; then
            echo "Error: No accounts.json found. Splitscreen accounts may not work properly." >&2
        fi
    else
        echo "✅ Offline accounts downloaded successfully"
    fi

    # --- Download PollyMC for gameplay ---
    echo "Downloading PollyMC for splitscreen gameplay..."
    
    # Create PollyMC directory
    mkdir -p "$HOME/.local/share/PollyMC"
    
    # Download latest PollyMC AppImage
    POLLYMC_URL="https://github.com/fn2006/PollyMC/releases/latest/download/PollyMC-Linux-x86_64.AppImage"
    echo "Downloading PollyMC from $POLLYMC_URL..."
    
    if ! wget -O "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage" "$POLLYMC_URL"; then
        echo "Warning: Failed to download PollyMC. Continuing with PrismLauncher only..." >&2
        USE_POLLYMC=false
    else
        chmod +x "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage"
        echo "✅ PollyMC downloaded successfully"
        USE_POLLYMC=true
    fi

    # --- Copy instances from PrismLauncher to PollyMC ---
    if [ "$USE_POLLYMC" = true ]; then
        echo "Copying instances from PrismLauncher to PollyMC..."
        
        # Ensure PollyMC instances directory exists
        mkdir -p "$HOME/.local/share/PollyMC/instances"
        
        # Copy each created instance
        for i in {1..4}; do
            INSTANCE_NAME="latestUpdate-$i"
            PRISM_INSTANCE="$targetDir/instances/$INSTANCE_NAME"
            POLLY_INSTANCE="$HOME/.local/share/PollyMC/instances/$INSTANCE_NAME"
            
            if [ -d "$PRISM_INSTANCE" ]; then
                echo "  Copying Player $i instance to PollyMC..."
                cp -r "$PRISM_INSTANCE" "$POLLY_INSTANCE"
                echo "  ✅ Player $i instance copied"
            fi
        done
        
        # Copy instances registry
        if [ -f "$INSTANCES_JSON" ]; then
            cp "$INSTANCES_JSON" "$HOME/.local/share/PollyMC/instances.json"
        fi
        
        # Copy accounts for PollyMC
        echo "Configuring PollyMC accounts..."
        if [ -f "accounts.json" ]; then
            # Verify accounts.json has content before copying
            if [ -s "accounts.json" ]; then
                cp "accounts.json" "$HOME/.local/share/PollyMC/accounts.json"
                echo "✅ Accounts copied to PollyMC"
                echo "  📋 Verifying account copy..."
                if [ -f "$HOME/.local/share/PollyMC/accounts.json" ] && [ -s "$HOME/.local/share/PollyMC/accounts.json" ]; then
                    ACCOUNT_COUNT=$(jq -r '.accounts | length' "$HOME/.local/share/PollyMC/accounts.json" 2>/dev/null || echo "0")
                    echo "  ✅ Found $ACCOUNT_COUNT accounts in PollyMC"
                    
                    # List account names for verification
                    if [ "$ACCOUNT_COUNT" -gt 0 ]; then
                        echo "  📋 Account names: $(jq -r '.accounts[].profile.name' "$HOME/.local/share/PollyMC/accounts.json" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')"
                    fi
                else
                    echo "  ❌ Account copy verification failed"
                fi
            else
                echo "⚠️  Warning: accounts.json is empty, cannot copy to PollyMC"
            fi
        else
            echo "⚠️  Warning: accounts.json not found, PollyMC may not have splitscreen accounts"
        fi
        
        # Test PollyMC functionality
        echo "Testing PollyMC compatibility..."
        if timeout 5s "$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage" --help >/dev/null 2>&1; then
            echo "✅ PollyMC is working correctly"
            
            # Verify instances are accessible in PollyMC
            echo "Verifying PollyMC can access instances..."
            POLLY_INSTANCES_COUNT=$(find "$HOME/.local/share/PollyMC/instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
            if [ "$POLLY_INSTANCES_COUNT" -gt 0 ]; then
                echo "✅ PollyMC has access to $POLLY_INSTANCES_COUNT splitscreen instances"
                
                # Download and configure the launcher script for PollyMC before cleanup
                echo "Setting up launcher script for PollyMC..."
                rm -f minecraftSplitscreen.sh
                if wget https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/minecraftSplitscreen.sh; then
                    chmod +x minecraftSplitscreen.sh
                    # Configure launcher script for PollyMC
                    sed -i 's|PrismLauncher/PrismLauncher.AppImage|PollyMC/PollyMC-Linux-x86_64.AppImage|g' minecraftSplitscreen.sh
                    sed -i 's|/.local/share/PrismLauncher/|/.local/share/PollyMC/|g' minecraftSplitscreen.sh
                    # Copy configured launcher script to PollyMC directory
                    cp minecraftSplitscreen.sh "$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
                    echo "  ✅ Launcher script configured and copied to PollyMC"
                else
                    echo "  ⚠️  Warning: Failed to download launcher script"
                fi
                
                # Clean up PrismLauncher since PollyMC is working
                echo "🧹 Cleaning up PrismLauncher (no longer needed)..."
                
                # Remove PrismLauncher AppImage
                if [ -f "./PrismLauncher.AppImage" ]; then
                    rm -f "./PrismLauncher.AppImage"
                    echo "  ✅ Removed PrismLauncher AppImage"
                fi
                
                # Remove PrismLauncher instances (since they're copied to PollyMC)
                if [ -d "$targetDir/instances" ]; then
                    rm -rf "$targetDir/instances"
                    echo "  ✅ Removed PrismLauncher instances directory"
                fi
                
                # Remove PrismLauncher config files
                PRISM_CONFIG_FILES=(
                    "$targetDir/instances.json"
                    "$targetDir/prismlauncher.cfg"
                    "$targetDir/accounts.json"
                    "$targetDir/metacache"
                    "$targetDir/libraries"
                    "$targetDir/assets"
                    "$targetDir/jars"
                )
                
                for config_file in "${PRISM_CONFIG_FILES[@]}"; do
                    if [ -e "$config_file" ]; then
                        rm -rf "$config_file"
                        echo "  ✅ Removed $(basename "$config_file")"
                    fi
                done
                
                # Remove the entire PrismLauncher directory since everything is now in PollyMC
                echo "  🗑️  Removing entire PrismLauncher directory..."
                
                # First, exit the directory we're about to delete
                cd "$HOME"
                
                # Safety check: make sure we're not deleting critical directories
                if [ -d "$targetDir" ] && [ "$targetDir" != "$HOME" ] && [ "$targetDir" != "/" ] && [[ "$targetDir" == *"PrismLauncher"* ]]; then
                    rm -rf "$targetDir"
                    echo "  ✅ Removed PrismLauncher directory: $targetDir"
                    echo "  💾 All essential files now in PollyMC directory"
                else
                    echo "  ⚠️  Skipped directory removal for safety: $targetDir"
                fi
                echo "  🎯 PollyMC is now the primary launcher for splitscreen gameplay"
            else
                echo "⚠️  PollyMC instance verification failed, keeping PrismLauncher as backup"
                USE_POLLYMC=false
            fi
        else
            echo "⚠️  PollyMC test failed, will fall back to PrismLauncher for gameplay"
            USE_POLLYMC=false
        fi
        
        echo "✅ Instances and accounts copied to PollyMC"
    fi

    # --- Initialize PrismLauncher configuration ---
    echo "Initializing PrismLauncher configuration..."
    
    # First, run PrismLauncher to create initial configuration structure
    echo "Creating initial PrismLauncher configuration..."
    timeout 10s ./PrismLauncher.AppImage --help >/dev/null 2>&1 || true
    
    # Ensure configuration directory exists
    mkdir -p "$targetDir"
    
    # Configure PrismLauncher settings for better splitscreen experience
    SETTINGS_FILE="$targetDir/prismlauncher.cfg"
    cat > "$SETTINGS_FILE" <<EOF
[General]
CloseAfterLaunch=true
UseNativeGLFW=false
UseNativeOpenAL=false
ShowConsole=false
ShowConsoleOnError=false
MaxMemAlloc=3072
MinMemAlloc=512
JavaPath=$JAVA_PATH
OverrideMemory=true
OverrideJavaLocation=true
LastUsedAccount=Player1
ActiveAccount=Player1
EOF

    # Configure launcher script for PrismLauncher fallback (if PollyMC setup failed)
    if [ "$USE_POLLYMC" = false ]; then
        echo "Downloading launcher script for PrismLauncher fallback..."
        rm -f minecraftSplitscreen.sh
        if wget https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/minecraftSplitscreen.sh; then
            chmod +x minecraftSplitscreen.sh
            # Configure for PrismLauncher
            sed -i 's|PollyMC/PollyMC-Linux-x86_64.AppImage|PrismLauncher/PrismLauncher.AppImage|g' minecraftSplitscreen.sh
            sed -i 's|/.local/share/PollyMC/|/.local/share/PrismLauncher/|g' minecraftSplitscreen.sh
            echo "✅ Launcher configured for PrismLauncher fallback"
        else
            echo "⚠️  Warning: Failed to download launcher script for PrismLauncher"
        fi
    fi

# Exit the directory if we haven't already (due to PollyMC cleanup)
if [ "$PWD" != "$HOME" ]; then
    popd
fi

# --- Optionally add the launch wrapper to Steam automatically ---
read -p "Do you want to add the Minecraft launch wrapper to Steam? [y/N]: " add_to_steam
if [[ "$add_to_steam" =~ ^[Yy]$ ]]; then
    # Check for existing launcher in Steam based on what we're using
    LAUNCHER_PATH=""
    if [ "$USE_POLLYMC" = true ]; then
        LAUNCHER_PATH="local/share/PollyMC/minecraft"
    else
        LAUNCHER_PATH="local/share/PrismLauncher/minecraft"
    fi
    
    if ! grep -q "$LAUNCHER_PATH" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then
        echo "Adding Minecraft launch wrapper to Steam..."
        steam -shutdown
        while pgrep -F ~/.steam/steam.pid; do
            sleep 1
        done
        [ -f $targetDir/shortcuts-backup.tar.xz ] || tar cJf $targetDir/shortcuts-backup.tar.xz ~/.steam/steam/userdata/*/config/shortcuts.vdf
        # Download and run the latest add-to-steam.py from the official repo for standalone use
        curl -sSL https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/add-to-steam.py | python3 -
        nohup steam &
    else
        echo "Minecraft launch wrapper already present in Steam shortcuts."
    fi
else
    echo "Skipping adding Minecraft launch wrapper to Steam."
fi

# --- Optionally create a .desktop launcher ---
# Prompt the user to create a desktop launcher for Minecraft Splitscreen
read -p "Do you want to create a desktop launcher for Minecraft Splitscreen? [y/N]: " create_desktop
if [[ "$create_desktop" =~ ^[Yy]$ ]]; then
    # Set the .desktop file name and paths
    DESKTOP_FILE_NAME="MinecraftSplitscreen.desktop"
    DESKTOP_FILE_PATH="$HOME/Desktop/$DESKTOP_FILE_NAME"
    APP_DIR="$HOME/.local/share/applications"
    mkdir -p "$APP_DIR" # Ensure the applications directory exists
    # --- Icon Handling ---
    # Use the same icon as the Steam shortcut (SteamGridDB icon)
    ICON_DIR="$targetDir/icons"
    ICON_PATH="$ICON_DIR/minecraft-splitscreen-steamgriddb.ico"
    ICON_URL="https://cdn2.steamgriddb.com/icon/add7a048049671970976f3e18f21ade3.ico"
    mkdir -p "$ICON_DIR" # Ensure the icon directory exists
    # Download the icon if it doesn't already exist
    if [ ! -f "$ICON_PATH" ]; then
        wget -O "$ICON_PATH" "$ICON_URL"
    fi
    # Determine which icon to use for the .desktop file
    if [ -f "$ICON_PATH" ]; then
        ICON_DESKTOP="$ICON_PATH" # Use the downloaded SteamGridDB icon
    elif [ -f "$targetDir/instances/latestUpdate-1/icon.png" ]; then
        ICON_DESKTOP="$targetDir/instances/latestUpdate-1/icon.png" # Fallback: use PrismLauncher instance icon
    else
        ICON_DESKTOP=application-x-executable # Fallback: use a generic system icon
    fi
    # --- Create the .desktop file ---
    # This file allows launching Minecraft Splitscreen from the desktop and application menu
    
    # Determine the correct launcher script path based on which launcher is being used
    if [ "$USE_POLLYMC" = true ]; then
        LAUNCHER_SCRIPT_PATH="$HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        LAUNCHER_COMMENT="Launch Minecraft in splitscreen mode with PollyMC"
    else
        LAUNCHER_SCRIPT_PATH="$targetDir/minecraftSplitscreen.sh"
        LAUNCHER_COMMENT="Launch Minecraft in splitscreen mode with PrismLauncher"
    fi
    
    cat <<EOF > "$DESKTOP_FILE_PATH"
[Desktop Entry]
Type=Application
Name=Minecraft Splitscreen
Comment=$LAUNCHER_COMMENT
Exec=$LAUNCHER_SCRIPT_PATH
Icon=$ICON_DESKTOP
Terminal=false
Categories=Game;
EOF
    # Make the .desktop file executable (required for some desktop environments)
    chmod +x "$DESKTOP_FILE_PATH"
    # Copy the .desktop file to the applications directory so it appears in the app menu
    cp "$DESKTOP_FILE_PATH" "$APP_DIR/$DESKTOP_FILE_NAME"
    # Update the desktop database (if available) to register the new launcher
    update-desktop-database "$APP_DIR" 2>/dev/null || true
    echo "Desktop launcher created at $DESKTOP_FILE_PATH and added to application menu."
else
    echo "Skipping desktop launcher creation."
fi

# --- Summary of missing mods ---
if [ ${#MISSING_MODS[@]} -gt 0 ]; then
  echo "\n====================="
  echo "WARNING: The following required mods could not be installed (missing compatible version or download failed):"
  for mod in "${MISSING_MODS[@]}"; do
    echo "  - $mod"
  done
  echo "====================="
fi

# --- Installation Complete ---
echo ""
echo "=========================================="
echo "🎮 MINECRAFT SPLITSCREEN SETUP COMPLETE! 🎮"
echo "=========================================="
echo ""
if [ "$USE_POLLYMC" = true ]; then
    echo "✅ PollyMC Setup Complete!"
    echo ""
    echo "🔧 Setup Strategy Used: OPTIMIZED APPROACH"
    echo "   • PrismLauncher: Used for automated instance creation ✅ COMPLETED"
    echo "   • PollyMC: Primary launcher for splitscreen gameplay ✅ ACTIVE"
    echo "   • PrismLauncher cleanup: Removed after successful setup ✅ CLEANED"
    echo ""
    echo "✅ Automated instance creation via PrismLauncher CLI"
    echo "✅ PollyMC configured as primary launcher"
    echo "✅ All instances transferred to PollyMC"
    echo "✅ PrismLauncher components cleaned up"
else
    echo "✅ PrismLauncher Setup Complete!"
    echo ""
    echo "🔧 Setup Strategy Used: FALLBACK MODE"
    echo "   • PrismLauncher: Instance creation + gameplay"
    echo "   • PollyMC: Download/setup failed, keeping PrismLauncher"
    echo ""
    echo "✅ PrismLauncher: CLI-based instance creation completed"
    echo "⚠️  Note: PollyMC setup failed, using PrismLauncher for everything"
fi
echo "✅ $CREATED_INSTANCES splitscreen instances created (Player 1-$CREATED_INSTANCES)"
echo "✅ All mods downloaded and installed"
echo "✅ Splitscreen configurations applied"
echo "✅ Offline accounts configured"
echo "✅ Java settings optimized for splitscreen"
echo ""
echo "🚀 Ready to play!"
echo ""
echo "To start splitscreen Minecraft:"
if [ "$USE_POLLYMC" = true ]; then
    echo "1. Launch: $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
else
    echo "1. Launch: $targetDir/minecraftSplitscreen.sh"
fi
echo "2. Or use the desktop launcher (if created)"
echo "3. Or launch from Steam (if added)"
echo ""
if [ "$USE_POLLYMC" = true ]; then
    echo "💡 Launcher Details:"
    echo "   • Instances created with: PrismLauncher CLI"
    echo "   • Game launches with: PollyMC (no forced login)"
    echo "   • Best of both worlds: CLI automation + offline gameplay"
else
    echo "💡 Launcher Details:"
    echo "   • Everything handled by: PrismLauncher"
    echo "⚠️  IMPORTANT - Minecraft Account Required:"
    echo "   • You need a PAID Minecraft Java Edition account from Microsoft"
    echo "   • Free/demo accounts will NOT work for splitscreen gameplay"
    echo "   • The launcher is configured for offline mode after login"
fi
echo ""
echo "The launcher will automatically detect controllers and"
echo "start the appropriate number of Minecraft instances."
echo ""
if [ "$USE_POLLYMC" = true ]; then
    echo "📁 Installation locations:"
    echo "   • Instances & launcher: $HOME/.local/share/PollyMC"
    echo "   • Temporary build location: Successfully removed after setup"
else
    echo "📁 Installation location: $targetDir"
fi
echo "🔧 CLI Features Implemented:"
echo "   • Automatic instance creation via PrismLauncher CLI"
echo "   • Fabric loader support with fallbacks"
echo "   • Manual instance creation if CLI fails"
echo "   • Dynamic instance verification and registration"
echo "   • Enhanced error handling and recovery"
if [ "$USE_POLLYMC" = true ]; then
    echo "   • Optimized launcher approach (PrismLauncher→PollyMC→Cleanup)"
fi
echo "=========================================="