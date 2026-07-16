#!/bin/bash
# =============================================================================
# JAVA MANAGEMENT MODULE
# _java_output_matches_major: does `java -version` output $2 report major $1?
# #48: the per-major match tables (8/16/17/21/23/24, four copies) silently
# lacked Java 25 — a correctly installed jdk-25 (required by MC 26.x) was
# undetectable offline. One generic pattern instead of a table to maintain.
_java_output_matches_major() {
    local major="$1" output="$2"
    if [[ "$major" == "8" ]]; then
        echo "$output" | grep -q '1\.8\|openjdk version "8'
    else
        echo "$output" | grep -q "openjdk version \"${major}\|java version \"${major}"
    fi
}

# =============================================================================
# Automatic Java detection, installation and management functions

# _mc_version_to_java_major: offline fallback table mapping a Minecraft version
# to its required Java major. Used ONLY when the Mojang manifest is unreachable
# or lacks the version — the API's javaVersion.majorVersion always wins when
# available. #48: this table previously existed as four verbatim copies inside
# get_required_java_version, and none of them knew the 2026 yearly scheme
# (26.x), so any 26.x version fell through to "8" offline — the installer
# picked Java 8 for a Java-25 game.
# Parameters:
#   $1 - mc_version (e.g., "1.21.3", "26.1.2")
# Returns: Java major on stdout (e.g., "25", "21", "17", "16", "8")
_mc_version_to_java_major() {
    local mc_version="$1"
    if [[ "$mc_version" =~ ^[2-9][0-9]+\. ]]; then
        # 2026 yearly scheme (26.x+): ships against Java 25 (verified: MC 26.1.2
        # installs jdk-25 via the manifest path). Same scheme test as
        # lwjgl_management.sh:get_lwjgl_version_by_mapping.
        echo "25"
    elif [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
        echo "21"  # 1.21+ requires Java 21
    elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
        echo "17"  # 1.18-1.20 requires Java 17
    elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
        echo "16"  # 1.17 requires Java 16
    else
        echo "8"   # 1.16 and below work with / require Java 8
    fi
}

# get_required_java_version: Determine the required Java version for a Minecraft version
# Fetches version manifest from Mojang API to get the official Java requirements
# Parameters:
#   $1 - mc_version: Minecraft version (e.g., "1.21.3")
# Returns: Java version number (e.g., "21", "17", "8") or exits on error
get_required_java_version() {
    local mc_version="$1"
    
    if [[ -z "$mc_version" ]]; then
        return 1
    fi
    
    # Get version manifest from Mojang API (silent)
    local manifest_url="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    # Fix #51 (D14): fetch_url replaces the bare curl call.
    local manifest_json
    manifest_json=$(fetch_url "$manifest_url" - 2>/dev/null)
    
    if [[ -z "$manifest_json" ]]; then
        # Fallback logic based on known Minecraft Java requirements
        _mc_version_to_java_major "$mc_version"
        return 0
    fi
    
    # Extract the version-specific manifest URL
    local version_url
    version_url=$(echo "$manifest_json" | jq -r --arg v "$mc_version" '.versions[] | select(.id == $v) | .url' 2>/dev/null)
    
    if [[ -z "$version_url" || "$version_url" == "null" ]]; then
        # Use same fallback logic as above
        _mc_version_to_java_major "$mc_version"
        return 0
    fi
    
    # Fetch the specific version manifest (silent)
    # Fix #51 (D14): fetch_url replaces the bare curl call.
    local version_json
    version_json=$(fetch_url "$version_url" - 2>/dev/null)
    
    if [[ -z "$version_json" ]]; then
        # Fallback logic
        _mc_version_to_java_major "$mc_version"
        return 0
    fi
    
    # Extract Java version requirement from the manifest
    local java_version
    java_version=$(echo "$version_json" | jq -r '.javaVersion.majorVersion // empty' 2>/dev/null)
    
    if [[ -n "$java_version" && "$java_version" != "null" ]]; then
        echo "$java_version"
    else
        # Fallback logic
        _mc_version_to_java_major "$mc_version"
    fi
}

# download_and_install_jdk: Download and install JDK directly from Eclipse Temurin (Adoptium).
# Queries the Adoptium API for the latest release of the requested major version,
# downloads the tarball, verifies its SHA-256 checksum, extracts it under the
# app's own data dir ($TARGET_DIR/java — #41: keep the install self-contained,
# nothing at the top of HOME), and exports JAVA_<version>_HOME so the caller can
# locate the new binary immediately. In-process export ONLY — no ~/.profile
# edits (#41): the resolved JAVA_PATH is baked into polymc.cfg/instance.cfg at
# install time and find_java_installation scans the install dirs directly, so
# nothing needs the variable after this installer run ends.
# No git, no third-party installer scripts.
# Parameters:
#   $1 - required_version: Required Java major version (e.g., "21", "17", "8")
download_and_install_jdk() {
    local required_version="$1"
    local install_dir="${TARGET_DIR:-$HOME/.local/share/PolyMC}/java"
    local arch="x64"
    local adoptium_api="https://api.adoptium.net/v3/assets/latest/${required_version}/hotspot"

    print_progress "Querying Eclipse Temurin API for JDK $required_version..."

    # Fix #51 (D14): fetch_url replaces the bare curl call.
    local api_response
    api_response=$(fetch_url \
        "${adoptium_api}?os=linux&architecture=${arch}&image_type=jdk" - \
        2>/dev/null)

    if [[ -z "$api_response" ]]; then
        print_error "Failed to reach Adoptium API. Check your internet connection."
        return 1
    fi

    local download_url
    download_url=$(echo "$api_response" | jq -r '.[0].binary.package.link // empty' 2>/dev/null)
    local expected_checksum
    expected_checksum=$(echo "$api_response" | jq -r '.[0].binary.package.checksum // empty' 2>/dev/null)
    local release_name
    release_name=$(echo "$api_response" | jq -r '.[0].release_name // "unknown"' 2>/dev/null)

    if [[ -z "$download_url" ]]; then
        print_error "Adoptium API returned no download URL for JDK $required_version."
        return 1
    fi

    print_info "Downloading Eclipse Temurin $release_name..."

    local temp_dir
    temp_dir=$(mktemp -d)
    local tarball="$temp_dir/jdk.tar.gz"

    if ! curl -fL --progress-bar "$download_url" -o "$tarball"; then
        print_error "Download failed: $download_url"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ -n "$expected_checksum" ]]; then
        print_progress "Verifying SHA-256 checksum..."
        local actual_checksum
        actual_checksum=$(sha256sum "$tarball" | cut -d' ' -f1)
        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            print_error "Checksum mismatch — download may be corrupt. Aborting."
            print_error "  Expected: $expected_checksum"
            print_error "  Got:      $actual_checksum"
            rm -rf "$temp_dir"
            return 1
        fi
        print_success "Checksum verified."
    fi

    mkdir -p "$install_dir"
    print_progress "Extracting JDK to $install_dir ..."

    if ! tar -xzf "$tarball" -C "$install_dir"; then
        print_error "Failed to extract JDK tarball."
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"

    # Locate the extracted JDK directory (Temurin names it jdk-<version>+<build> or jdk8u<n>-...)
    local jdk_dir
    jdk_dir=$(find "$install_dir" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)

    if [[ -z "$jdk_dir" || ! -x "$jdk_dir/bin/java" ]]; then
        print_error "JDK extracted but java binary not found. Expected it under $install_dir."
        return 1
    fi

    # In-process export only — deliberately NOT persisted to ~/.profile (#41).
    # Editing the user's shell profile is a global side effect that lingers
    # after uninstall; nothing outside this installer run reads the variable.
    local java_home_var="JAVA_${required_version}_HOME"
    export "${java_home_var}=${jdk_dir}"

    print_success "Eclipse Temurin JDK $required_version installed to: $jdk_dir"
    return 0
}

# Keep the old name as a thin alias so any external callers are not broken.
download_and_run_jdk_installer() {
    download_and_install_jdk "$@"
}

# find_java_installation: Find a Java installation of the specified version
# Searches both system locations and the automatic installer location
# Parameters:
#   $1 - required_version: Required Java major version (e.g., "21", "17", "8")
# Returns: Path to Java executable or empty string if not found
find_java_installation() {
    local required_version="$1"
    local java_path=""
    
    # First, check a JAVA_<ver>_HOME exported by this run's automatic install
    local jdk_home_var="JAVA_${required_version}_HOME"
    if [[ -n "${!jdk_home_var:-}" && -x "${!jdk_home_var}/bin/java" ]]; then
        java_path="${!jdk_home_var}/bin/java"
        echo "$java_path"
        return 0
    fi
    
    # Scan the app-owned install dir, then legacy locations from older
    # installers (~/.local/jdk, ~/java — #41 relocated new installs but
    # existing ones keep working without a re-download).
    local scan_root
    for scan_root in "${TARGET_DIR:-$HOME/.local/share/PolyMC}/java" "$HOME/.local/jdk" "$HOME/java"; do
        [[ -n "$java_path" ]] && break
        [[ -d "$scan_root" ]] || continue
        for jdk_dir in "$scan_root"/*/; do
            if [[ -x "${jdk_dir}bin/java" ]]; then
                local version_output
                version_output=$("${jdk_dir}bin/java" -version 2>&1 | head -1)
                # #48: generic major match (was a per-major table missing Java 25).
                if _java_output_matches_major "$required_version" "$version_output"; then
                    java_path="${jdk_dir}bin/java"
                    break
                fi
            fi
        done
    done
    
    # Check system locations if not found in ~/.local/jdk
    if [[ -z "$java_path" ]]; then
        # #48: generic candidate list (was a per-major table of the same three
        # path shapes, missing Java 25 and every future major). The java-1.8.0
        # legacy name is the 8-only special case.
        local _jvm_candidates=(
            "/usr/lib/jvm/java-${required_version}-openjdk/bin/java"
            "/usr/lib/jvm/java-${required_version}-oracle/bin/java"
            "/usr/lib/jvm/jdk-${required_version}/bin/java"
            "/usr/lib/jvm/zulu${required_version}/bin/java"
        )
        [[ "$required_version" == "8" ]] && _jvm_candidates+=("/usr/lib/jvm/java-1.8.0-openjdk/bin/java")
        local path
        for path in "${_jvm_candidates[@]}"; do
            if [[ -x "$path" ]]; then
                java_path="$path"
                break
            fi
        done
    fi
    
    # Check system default java and validate version
    if [[ -z "$java_path" ]] && command -v java >/dev/null 2>&1; then
        local version_output
        version_output=$(java -version 2>&1 | head -1)
        # #48: generic major match (was a per-major table missing Java 25).
        if _java_output_matches_major "$required_version" "$version_output"; then
            java_path="java"
        fi
    fi
    
    echo "$java_path"
}

# detect_and_install_java: Find required Java version and install if needed
# This function automatically detects the required Java version, searches for it,
# and installs it automatically if not found. No user interaction required.
# Must be called after MC_VERSION is set
detect_and_install_java() {
    if [[ -z "${MC_VERSION:-}" ]]; then
        print_error "MC_VERSION must be set before calling detect_and_install_java"
        exit 1
    fi
    
    print_header "☕ AUTOMATIC JAVA SETUP"
    
    # Get the required Java version for this Minecraft version
    print_progress "Checking Java requirements for Minecraft $MC_VERSION..."
    local required_java_version
    required_java_version=$(get_required_java_version "$MC_VERSION")
    
    print_info "Minecraft $MC_VERSION requires Java $required_java_version"
    
    # Search for existing Java installation
    print_progress "Searching for Java $required_java_version installation..."
    
    # Source the profile to get any existing Java environment variables
    [[ -f ~/.profile ]] && source ~/.profile 2>/dev/null || true
    
    JAVA_PATH=$(find_java_installation "$required_java_version")
    
    if [[ -n "$JAVA_PATH" ]]; then
        # Validate that the found Java is actually the correct version
        local java_version_output
        java_version_output=$("$JAVA_PATH" -version 2>&1)
        
        # Verify version matches requirement
        local version_matches=false
        # #48: generic major match (was a per-major table missing Java 25).
        if _java_output_matches_major "$required_java_version" "$java_version_output"; then
            version_matches=true
        fi
        
        if [[ "$version_matches" == true ]]; then
            print_success "Found compatible Java $required_java_version at: $JAVA_PATH"
            local java_version_line
            java_version_line=$(echo "$java_version_output" | head -1)
            print_info "Version info: $java_version_line"
            return 0
        else
            print_warning "Found Java executable but version doesn't match requirement"
            JAVA_PATH=""  # Clear invalid path
        fi
    fi
    
    # Java not found or wrong version - install automatically
    print_warning "Java $required_java_version not found on system"
    print_info "Automatically installing Eclipse Temurin JDK $required_java_version..."
    print_info "This installation:"
    print_info "  • Downloads from Eclipse Temurin (Adoptium) with SHA-256 verification"
    print_info "  • Installs to ${TARGET_DIR:-$HOME/.local/share/PolyMC}/java/ (self-contained, no root access needed)"
    print_info "  • Supports multiple Java versions side-by-side"
    print_info "  • Leaves your shell profile untouched"
    
    # Attempt automatic installation
    if download_and_run_jdk_installer "$required_java_version"; then
        # Source the updated profile to load new environment variables
        [[ -f ~/.profile ]] && source ~/.profile 2>/dev/null || true
        
        # Try to find the newly installed Java
        JAVA_PATH=$(find_java_installation "$required_java_version")
        
        if [[ -n "$JAVA_PATH" ]]; then
            print_success "Java $required_java_version automatically installed and configured!"
            local java_version_output
            java_version_output=$("$JAVA_PATH" -version 2>&1)
            local java_version_line
            java_version_line=$(echo "$java_version_output" | head -1)
            print_info "Installation location: $JAVA_PATH"
            print_info "Version info: $java_version_line"
            return 0
        else
            print_error "Java installation completed but executable not found"
            print_error "Please restart your terminal and try running the script again"
            exit 1
        fi
    else
        print_error "Automatic Java installation failed"
        print_error "Please install Java $required_java_version manually and try again"
        print_info "Manual installation options:"
        # #48: generic suggestion (was a per-major table stopping at 21 — a
        # Java-25 requirement, MC 26.x, printed no package hint at all).
        if [[ "$required_java_version" == "16" ]]; then
            print_info "  • Java 16 is deprecated, consider Java 17 (compatible)"
            print_info "  • System package: sudo pacman -S jdk17-openjdk"
        else
            print_info "  • System package: sudo pacman -S jdk${required_java_version}-openjdk"
            print_info "  • Download from: https://adoptium.net/temurin/releases/?version=${required_java_version}"
        fi
        print_info "  • Or download directly from Eclipse Temurin:"
        print_info "    https://adoptium.net/temurin/releases/?version=${required_java_version}&os=linux&arch=x64&package=jdk"
        exit 1
    fi
}

# Legacy function name for backward compatibility
detect_java() {
    detect_and_install_java
}
