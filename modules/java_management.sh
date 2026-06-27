#!/bin/bash
# =============================================================================
# JAVA MANAGEMENT MODULE
# =============================================================================
# Automatic Java detection, installation and management functions

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
    local manifest_json
    manifest_json=$(curl -s "$manifest_url" 2>/dev/null)
    
    if [[ -z "$manifest_json" ]]; then
        # Fallback logic based on known Minecraft Java requirements
        if [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
            echo "21"  # 1.21+ requires Java 21
        elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
            echo "17"  # 1.18-1.20 requires Java 17
        elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
            echo "16"  # 1.17 requires Java 16
        elif [[ "$mc_version" =~ ^1\.(1[3-6])(\.|$) ]]; then
            echo "8"   # 1.13-1.16 works with Java 8
        else
            echo "8"   # Older versions (1.12 and below) require Java 8
        fi
        return 0
    fi
    
    # Extract the version-specific manifest URL
    local version_url
    version_url=$(echo "$manifest_json" | jq -r --arg v "$mc_version" '.versions[] | select(.id == $v) | .url' 2>/dev/null)
    
    if [[ -z "$version_url" || "$version_url" == "null" ]]; then
        # Use same fallback logic as above
        if [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
            echo "21"
        elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
            echo "17"
        elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
            echo "16"
        elif [[ "$mc_version" =~ ^1\.(1[3-6])(\.|$) ]]; then
            echo "8"
        else
            echo "8"
        fi
        return 0
    fi
    
    # Fetch the specific version manifest (silent)
    local version_json
    version_json=$(curl -s "$version_url" 2>/dev/null)
    
    if [[ -z "$version_json" ]]; then
        # Fallback logic
        if [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
            echo "21"
        elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
            echo "17"
        elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
            echo "16"
        elif [[ "$mc_version" =~ ^1\.(1[3-6])(\.|$) ]]; then
            echo "8"
        else
            echo "8"
        fi
        return 0
    fi
    
    # Extract Java version requirement from the manifest
    local java_version
    java_version=$(echo "$version_json" | jq -r '.javaVersion.majorVersion // empty' 2>/dev/null)
    
    if [[ -n "$java_version" && "$java_version" != "null" ]]; then
        echo "$java_version"
    else
        # Fallback logic
        if [[ "$mc_version" =~ ^1\.2[1-9](\.|$) ]]; then
            echo "21"
        elif [[ "$mc_version" =~ ^1\.(1[8-9]|20)(\.|$) ]]; then
            echo "17"
        elif [[ "$mc_version" =~ ^1\.17(\.|$) ]]; then
            echo "16"
        elif [[ "$mc_version" =~ ^1\.(1[3-6])(\.|$) ]]; then
            echo "8"
        else
            echo "8"
        fi
    fi
}

# download_and_install_jdk: Download and install JDK directly from Eclipse Temurin (Adoptium).
# Queries the Adoptium API for the latest release of the requested major version,
# downloads the tarball, verifies its SHA-256 checksum, extracts it to ~/.local/jdk/,
# and exports JAVA_<version>_HOME so the caller can locate the new binary immediately.
# No git, no third-party installer scripts.
# Parameters:
#   $1 - required_version: Required Java major version (e.g., "21", "17", "8")
download_and_install_jdk() {
    local required_version="$1"
    local install_dir="$HOME/.local/jdk"
    local arch="x64"
    local adoptium_api="https://api.adoptium.net/v3/assets/latest/${required_version}/hotspot"

    print_progress "Querying Eclipse Temurin API for JDK $required_version..."

    local api_response
    api_response=$(curl -fsS "${adoptium_api}?os=linux&architecture=${arch}&image_type=jdk" 2>/dev/null)

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

    # Persist JAVA_<version>_HOME into ~/.profile, deduplicating any previous entry.
    local java_home_var="JAVA_${required_version}_HOME"
    if [[ -f ~/.profile ]]; then
        sed -i "/^export ${java_home_var}=/d" ~/.profile
    fi
    echo "export ${java_home_var}=\"${jdk_dir}\"" >> ~/.profile
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
    
    # First, check the automatic installer location (~/.local/jdk)
    local jdk_home_var="JAVA_${required_version}_HOME"
    if [[ -n "${!jdk_home_var:-}" && -x "${!jdk_home_var}/bin/java" ]]; then
        java_path="${!jdk_home_var}/bin/java"
        echo "$java_path"
        return 0
    fi
    
    # Check ~/.local/jdk directory directly (in case env vars aren't loaded)
    if [[ -d "$HOME/.local/jdk" ]]; then
        for jdk_dir in "$HOME/.local/jdk"/*/; do
            if [[ -x "${jdk_dir}bin/java" ]]; then
                local version_output
                version_output=$("${jdk_dir}bin/java" -version 2>&1 | head -1)
                case "$required_version" in
                    8)
                        if echo "$version_output" | grep -q "1\.8\|openjdk version \"8"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                    16)
                        if echo "$version_output" | grep -q "openjdk version \"16\|java version \"16"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                    17)
                        if echo "$version_output" | grep -q "openjdk version \"17\|java version \"17"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                    21)
                        if echo "$version_output" | grep -q "openjdk version \"21\|java version \"21"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                    23)
                        if echo "$version_output" | grep -q "openjdk version \"23\|java version \"23"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                    24)
                        if echo "$version_output" | grep -q "openjdk version \"24\|java version \"24"; then
                            java_path="${jdk_dir}bin/java"
                            break
                        fi
                        ;;
                esac
            fi
        done
    fi
    
    # Check system locations if not found in ~/.local/jdk
    if [[ -z "$java_path" ]]; then
        case "$required_version" in
            8)
                for path in "/usr/lib/jvm/java-8-openjdk/bin/java" \
                           "/usr/lib/jvm/java-1.8.0-openjdk/bin/java" \
                           "/usr/lib/jvm/zulu8/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
            16)
                for path in "/usr/lib/jvm/java-16-openjdk/bin/java" \
                           "/usr/lib/jvm/jdk-16/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
            17)
                for path in "/usr/lib/jvm/java-17-openjdk/bin/java" \
                           "/usr/lib/jvm/java-17-oracle/bin/java" \
                           "/usr/lib/jvm/zulu17/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
            21)
                for path in "/usr/lib/jvm/java-21-openjdk/bin/java" \
                           "/usr/lib/jvm/java-21-oracle/bin/java" \
                           "/usr/lib/jvm/zulu21/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
            23)
                for path in "/usr/lib/jvm/java-23-openjdk/bin/java" \
                           "/usr/lib/jvm/jdk-23/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
            24)
                for path in "/usr/lib/jvm/java-24-openjdk/bin/java" \
                           "/usr/lib/jvm/jdk-24/bin/java"; do
                    if [[ -x "$path" ]]; then
                        java_path="$path"
                        break
                    fi
                done
                ;;
        esac
    fi
    
    # Check system default java and validate version
    if [[ -z "$java_path" ]] && command -v java >/dev/null 2>&1; then
        local version_output
        version_output=$(java -version 2>&1 | head -1)
        case "$required_version" in
            8)
                if echo "$version_output" | grep -q "1\.8\|openjdk version \"8"; then
                    java_path="java"
                fi
                ;;
            16)
                if echo "$version_output" | grep -q "openjdk version \"16\|java version \"16"; then
                    java_path="java"
                fi
                ;;
            17)
                if echo "$version_output" | grep -q "openjdk version \"17\|java version \"17"; then
                    java_path="java"
                fi
                ;;
            21)
                if echo "$version_output" | grep -q "openjdk version \"21\|java version \"21"; then
                    java_path="java"
                fi
                ;;
            23)
                if echo "$version_output" | grep -q "openjdk version \"23\|java version \"23"; then
                    java_path="java"
                fi
                ;;
            24)
                if echo "$version_output" | grep -q "openjdk version \"24\|java version \"24"; then
                    java_path="java"
                fi
                ;;
        esac
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
        case "$required_java_version" in
            8)
                if echo "$java_version_output" | grep -q "1\.8\|openjdk version \"8"; then
                    version_matches=true
                fi
                ;;
            16)
                if echo "$java_version_output" | grep -q "openjdk version \"16\|java version \"16"; then
                    version_matches=true
                fi
                ;;
            17)
                if echo "$java_version_output" | grep -q "openjdk version \"17\|java version \"17"; then
                    version_matches=true
                fi
                ;;
            21)
                if echo "$java_version_output" | grep -q "openjdk version \"21\|java version \"21"; then
                    version_matches=true
                fi
                ;;
            23)
                if echo "$java_version_output" | grep -q "openjdk version \"23\|java version \"23"; then
                    version_matches=true
                fi
                ;;
            24)
                if echo "$java_version_output" | grep -q "openjdk version \"24\|java version \"24"; then
                    version_matches=true
                fi
                ;;
        esac
        
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
    print_info "  • Installs to ~/.local/jdk/ (no root access needed)"
    print_info "  • Supports multiple Java versions side-by-side"
    print_info "  • Sets up JAVA_${required_java_version}_HOME in ~/.profile automatically"
    
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
        case "$required_java_version" in
            "21")
                print_info "  • System package: sudo pacman -S jdk21-openjdk"
                print_info "  • Download from: https://adoptium.net/temurin/releases/?version=21"
                ;;
            "17")
                print_info "  • System package: sudo pacman -S jdk17-openjdk"
                print_info "  • Download from: https://adoptium.net/temurin/releases/?version=17"
                ;;
            "16")
                print_info "  • Java 16 is deprecated, consider Java 17 (compatible)"
                print_info "  • System package: sudo pacman -S jdk17-openjdk"
                ;;
            "8")
                print_info "  • System package: sudo pacman -S jdk8-openjdk"
                print_info "  • Download from: https://adoptium.net/temurin/releases/?version=8"
                ;;
        esac
        print_info "  • Or download directly from Eclipse Temurin:"
        print_info "    https://adoptium.net/temurin/releases/?version=${required_java_version}&os=linux&arch=x64&package=jdk"
        exit 1
    fi
}

# Legacy function name for backward compatibility
detect_java() {
    detect_and_install_java
}
