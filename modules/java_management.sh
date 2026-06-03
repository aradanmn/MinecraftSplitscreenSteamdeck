#!/bin/bash
# =============================================================================
# @file        java_management.sh
# @version     3.1.0
# @date        2026-06-03
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Automatic Java detection, installation, and management for Minecraft.
#   Determines the correct Java version required for any Minecraft version
#   by querying Mojang's API or using fallback version mappings.
#
#   Key features:
#   - Automatic Java version detection from Mojang API
#   - Fallback mappings: 1.21+ → Java 21, 1.18-1.20 → Java 17, 1.17 → Java 16, older → Java 8
#   - User-space installation to ~/.local/jdk/ (no root required)
#   - Multi-version coexistence support
#   - Automatic environment variable configuration
#
# @dependencies
#   - utilities.sh (for print_header, print_success, print_warning, print_error, print_info, print_progress)
#   - curl or wget (for Mojang API requests and JDK download)
#   - jq (for JSON parsing)
#   - tar (for JDK archive extraction)
#
# @global_outputs
#   - JAVA_PATH: Path to the detected/installed Java executable
#
# @exports
#   Functions:
#     - get_required_java_version : Determine Java version for MC version
#     - download_and_run_jdk_installer : Install Java automatically
#     - find_java_installation : Search for existing Java installation
#     - detect_and_install_java : Main function - find or install Java
#     - detect_java : Legacy alias for detect_and_install_java
#
# @changelog
#   3.1.0 (2026-06-03) - Feat: Internalize JDK install — download Eclipse Temurin directly from Adoptium, remove external git clone dependency
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# =============================================================================
# JAVA VERSION DETECTION
# =============================================================================

# @function    get_required_java_version
# @description Determine the required Java version for a Minecraft version.
#              Queries Mojang's version manifest API for official requirements,
#              falling back to version utilities if API unavailable.
# @param       $1 - mc_version: Minecraft version (e.g., "1.21.3")
# @stdout      Java version number (e.g., "21", "17", "8")
# @return      0 on success, 1 if mc_version is empty
# @example
#   required_java=$(get_required_java_version "1.21.3")  # Returns "21"
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
        # Use centralized version utility for fallback
        get_java_version_for_mc "$mc_version"
        return 0
    fi

    # Extract the version-specific manifest URL
    local version_url
    version_url=$(echo "$manifest_json" | jq -r --arg v "$mc_version" '.versions[] | select(.id == $v) | .url' 2>/dev/null)

    if [[ -z "$version_url" || "$version_url" == "null" ]]; then
        # Use centralized version utility for fallback
        get_java_version_for_mc "$mc_version"
        return 0
    fi

    # Fetch the specific version manifest (silent)
    local version_json
    version_json=$(curl -s "$version_url" 2>/dev/null)

    if [[ -z "$version_json" ]]; then
        # Use centralized version utility for fallback
        get_java_version_for_mc "$mc_version"
        return 0
    fi

    # Extract Java version requirement from the manifest
    local java_version
    java_version=$(echo "$version_json" | jq -r '.javaVersion.majorVersion // empty' 2>/dev/null)

    if [[ -n "$java_version" && "$java_version" != "null" ]]; then
        echo "$java_version"
    else
        # Use centralized version utility for fallback
        get_java_version_for_mc "$mc_version"
    fi
}

# =============================================================================
# JAVA INSTALLATION
# =============================================================================

# @function    download_and_run_jdk_installer
# @description Download Eclipse Temurin JDK from Adoptium and install to ~/.local/jdk/.
#              No external scripts or git required — pure curl/wget + tar.
# @param       $1 - required_version: Required Java major version (e.g., "21", "17", "8")
# @return      0 on successful installation, 1 on failure
# @example
#   download_and_run_jdk_installer "21"
download_and_run_jdk_installer() {
    local required_version="$1"

    # Map architecture to Adoptium arch name
    local arch
    case "$(uname -m)" in
        x86_64)         arch="x64" ;;
        aarch64|arm64)  arch="aarch64" ;;
        armv7l)         arch="arm" ;;
        *)
            print_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    local install_dir="$HOME/.local/jdk"
    mkdir -p "$install_dir" || { print_error "Cannot create $install_dir"; return 1; }

    local temp_dir
    temp_dir=$(mktemp -d) || { print_error "Cannot create temp directory"; return 1; }

    local adoptium_url="https://api.adoptium.net/v3/binary/latest/${required_version}/ga/linux/${arch}/jdk/hotspot/normal/eclipse"

    print_progress "Downloading Java ${required_version} (Eclipse Temurin) for ${arch}..."
    print_info "   Source: Adoptium API (adoptium.net)"

    local tarball="$temp_dir/jdk-${required_version}.tar.gz"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL --max-time 120 -o "$tarball" "$adoptium_url" 2>/dev/null; then
            print_error "Failed to download JDK ${required_version} from Adoptium"
            rm -rf "$temp_dir"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q --timeout=120 -O "$tarball" "$adoptium_url" 2>/dev/null; then
            print_error "Failed to download JDK ${required_version} from Adoptium"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        print_error "Neither curl nor wget is available — cannot download JDK"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ ! -s "$tarball" ]]; then
        print_error "Downloaded JDK archive is empty"
        rm -rf "$temp_dir"
        return 1
    fi

    print_progress "Installing Java ${required_version} to ${install_dir}..."

    local extract_dir="$temp_dir/extracted"
    mkdir -p "$extract_dir"

    if ! tar -xzf "$tarball" -C "$extract_dir" 2>/dev/null; then
        print_error "Failed to extract JDK archive"
        rm -rf "$temp_dir"
        return 1
    fi

    # Find the extracted JDK directory (Adoptium archives have one top-level dir)
    local extracted_jdk
    extracted_jdk=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)

    if [[ -z "$extracted_jdk" ]]; then
        print_error "Could not locate extracted JDK directory"
        rm -rf "$temp_dir"
        return 1
    fi

    # Install to ~/.local/jdk/<dirname> — remove any previous install for this version
    local jdk_dest="$install_dir/$(basename "$extracted_jdk")"
    rm -rf "$jdk_dest"
    mv "$extracted_jdk" "$jdk_dest" || {
        print_error "Failed to move JDK to $jdk_dest"
        rm -rf "$temp_dir"
        return 1
    }

    rm -rf "$temp_dir"

    if [[ ! -x "$jdk_dest/bin/java" ]]; then
        print_error "Java binary not found in installed JDK: $jdk_dest/bin/java"
        return 1
    fi

    # Export JAVA_N_HOME and persist to ~/.profile for future shells
    local env_var="JAVA_${required_version}_HOME"
    export "${env_var}=${jdk_dest}"

    # Add to ~/.profile if not already present
    local profile_line="export ${env_var}=\"${jdk_dest}\""
    if [[ -f "$HOME/.profile" ]]; then
        # Remove any stale entry for this variable before adding the updated one
        local tmp_profile
        tmp_profile=$(mktemp)
        grep -v "export ${env_var}=" "$HOME/.profile" > "$tmp_profile" 2>/dev/null || true
        echo "$profile_line" >> "$tmp_profile"
        mv "$tmp_profile" "$HOME/.profile"
    else
        echo "$profile_line" >> "$HOME/.profile"
    fi

    print_success "Java ${required_version} installed to ${jdk_dest}"
    return 0
}

# =============================================================================
# JAVA DETECTION
# =============================================================================

# @function    find_java_installation
# @description Find an existing Java installation of the specified version.
#              Search order: JAVA_N_HOME env vars → ~/.local/jdk/ → system paths → PATH
# @param       $1 - required_version: Required Java major version (e.g., "21", "17", "8")
# @stdout      Path to Java executable, or empty string if not found
# @return      0 if found, implicit failure if not found (empty stdout)
# @example
#   java_path=$(find_java_installation "21")
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

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# @function    detect_and_install_java
# @description Main function to find required Java version and install if needed.
#              Automatically detects requirements, searches for existing installation,
#              and installs if not found. No user interaction required.
# @global      MC_VERSION - (input) Must be set before calling
# @global      JAVA_PATH - (output) Set to path of Java executable
# @return      0 on success, exits on failure
# @example
#   MC_VERSION="1.21.3"
#   detect_and_install_java
#   echo "Java at: $JAVA_PATH"
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
    print_info "Automatically installing Java $required_java_version using Steam Deck JDK installer..."
    print_info "This installation:"
    print_info "  • Downloads official Oracle/OpenJDK builds with SHA256 verification"
    print_info "  • Installs to ~/.local/jdk/ (no root access needed)"
    print_info "  • Supports multiple Java versions side-by-side"
    print_info "  • Sets up proper environment variables automatically"

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
        print_info "  • Or run the JDK installer separately:"
        print_info "    See: ${REPO_URL}#java-installation for manual instructions"
        exit 1
    fi
}

