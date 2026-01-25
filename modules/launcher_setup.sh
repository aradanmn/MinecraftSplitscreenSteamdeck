#!/bin/bash
# =============================================================================
# LAUNCHER SETUP MODULE
# =============================================================================
# @file        launcher_setup.sh
# @version     2.2.1
# @date        2026-01-25
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Handles PrismLauncher detection, installation, and CLI verification.
#   PrismLauncher is used for automated Minecraft instance creation via CLI,
#   providing reliable instance management and Fabric loader installation.
#
#   On immutable Linux systems (Bazzite, SteamOS, etc.), this module prefers
#   installing PrismLauncher via Flatpak. On traditional systems, it downloads
#   the AppImage from GitHub releases.
#
# @dependencies
#   - curl (for GitHub API queries)
#   - jq (for JSON parsing)
#   - wget (for downloading AppImage)
#   - flatpak (optional, for Flatpak installation)
#   - utilities.sh (for print_* functions)
#   - path_configuration.sh (for path constants, setters, and PREFER_FLATPAK)
#
# @exports
#   Functions:
#     - download_prism_launcher : Detect or install PrismLauncher
#     - verify_prism_cli        : Verify CLI capabilities
#     - get_prism_executable    : Get executable path/command
#
#   Variables:
#     - PRISM_INSTALL_TYPE      : Installation type (appimage/flatpak)
#     - PRISM_EXECUTABLE        : Path or command to run PrismLauncher
#
# @changelog
#   2.2.1 (2026-01-25) - Fix: Only create directories after successful download
#   2.2.0 (2026-01-25) - Use PREFER_FLATPAK from path_configuration instead of calling should_prefer_flatpak()
#   2.1.0 (2026-01-24) - Added Flatpak preference for immutable OS, arch detection
#   2.0.0 (2026-01-23) - Refactored to use centralized path configuration
#   1.0.0 (2026-01-22) - Initial version
# =============================================================================

# Module-level variables for tracking installation
PRISM_INSTALL_TYPE=""
PRISM_EXECUTABLE=""

# -----------------------------------------------------------------------------
# @function    download_prism_launcher
# @description Detects existing PrismLauncher installation or installs it.
#              Uses different strategies based on the operating system:
#
#              On immutable OS (Bazzite, SteamOS, etc.):
#              1) Use existing Flatpak if installed
#              2) Install Flatpak from Flathub
#              3) Use existing AppImage if present
#              4) Download AppImage from GitHub
#
#              On traditional OS:
#              1) Use existing Flatpak if installed
#              2) Use existing AppImage if present
#              3) Download AppImage from GitHub
#
# @param       None
# @global      PREFER_FLATPAK         - (input) Whether to prefer Flatpak (from path_configuration)
# @global      PRISM_FLATPAK_ID       - (input) Flatpak application ID
# @global      PRISM_FLATPAK_DATA_DIR - (input) Flatpak data directory
# @global      PRISM_APPIMAGE_PATH    - (input) Expected AppImage location
# @global      PRISM_APPIMAGE_DATA_DIR - (input) AppImage data directory
# @return      0 on success, exits on critical failure
# @sideeffect  Calls set_creation_launcher_prismlauncher() to update paths
# -----------------------------------------------------------------------------
download_prism_launcher() {
    print_progress "Detecting PrismLauncher installation..."

    # Priority 1: Check for existing Flatpak installation
    if is_flatpak_installed "$PRISM_FLATPAK_ID" 2>/dev/null; then
        print_success "Found existing PrismLauncher Flatpak installation"

        mkdir -p "$PRISM_FLATPAK_DATA_DIR/instances"
        set_creation_launcher_prismlauncher "flatpak" "flatpak run $PRISM_FLATPAK_ID"
        print_info "   → Using Flatpak data directory: $PRISM_FLATPAK_DATA_DIR"
        return 0
    fi

    # Priority 2 (immutable OS only): Install Flatpak if preferred
    # PREFER_FLATPAK is set by configure_launcher_paths() in path_configuration.sh
    if [[ "$PREFER_FLATPAK" == true ]]; then
        print_info "Immutable OS detected - preferring Flatpak installation"

        if command -v flatpak &>/dev/null; then
            print_progress "Installing PrismLauncher via Flatpak..."

            # Ensure Flathub repo is available
            if ! flatpak remote-list | grep -q flathub; then
                print_progress "Adding Flathub repository..."
                flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
            fi

            # Install PrismLauncher Flatpak (user installation to avoid root)
            if flatpak install --user -y flathub "$PRISM_FLATPAK_ID" 2>/dev/null; then
                print_success "PrismLauncher Flatpak installed successfully"

                mkdir -p "$PRISM_FLATPAK_DATA_DIR/instances"
                set_creation_launcher_prismlauncher "flatpak" "flatpak run $PRISM_FLATPAK_ID"
                print_info "   → Using Flatpak data directory: $PRISM_FLATPAK_DATA_DIR"
                return 0
            else
                print_warning "Flatpak installation failed - falling back to AppImage"
            fi
        else
            print_warning "Flatpak not available - falling back to AppImage"
        fi
    fi

    # Priority 3: Check for existing AppImage
    if [[ -f "$PRISM_APPIMAGE_PATH" ]]; then
        print_success "PrismLauncher AppImage already present"

        set_creation_launcher_prismlauncher "appimage" "$PRISM_APPIMAGE_PATH"
        return 0
    fi

    # Priority 4: Download AppImage
    print_progress "No existing PrismLauncher found - downloading AppImage..."

    # Query GitHub API for latest release matching system architecture
    local prism_url
    local arch
    arch=$(uname -m)

    prism_url=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest | \
        jq -r --arg arch "$arch" '.assets[] | select(.name | test("AppImage$")) | select(.name | contains($arch)) | .browser_download_url' | head -n1)

    if [[ -z "$prism_url" || "$prism_url" == "null" ]]; then
        print_error "Could not find latest PrismLauncher AppImage URL."
        print_error "Please check https://github.com/PrismLauncher/PrismLauncher/releases manually."
        exit 1
    fi

    # Download to temp location first, only create directory on success
    local temp_appimage
    temp_appimage=$(mktemp)

    if ! wget -q -O "$temp_appimage" "$prism_url"; then
        print_error "Failed to download PrismLauncher AppImage."
        rm -f "$temp_appimage" 2>/dev/null
        exit 1
    fi

    # Download successful - now create directory and move file
    mkdir -p "$PRISM_APPIMAGE_DATA_DIR"
    mv "$temp_appimage" "$PRISM_APPIMAGE_PATH"
    chmod +x "$PRISM_APPIMAGE_PATH"

    set_creation_launcher_prismlauncher "appimage" "$PRISM_APPIMAGE_PATH"
    print_success "PrismLauncher AppImage downloaded successfully"
    print_info "   → Installation type: appimage"
}

# -----------------------------------------------------------------------------
# @function    verify_prism_cli
# @description Verifies that PrismLauncher supports CLI operations needed for
#              automated instance creation. Tests the --help output for CLI
#              keywords. If AppImage fails due to FUSE issues, attempts to
#              extract and run directly.
#
# @param       None
# @global      CREATION_LAUNCHER_TYPE - (input) "appimage" or "flatpak"
# @global      CREATION_EXECUTABLE    - (input/output) May be updated if extracted
# @global      CREATION_DATA_DIR      - (input) Data directory for extraction
# @global      PRISM_FLATPAK_ID       - (input) Flatpak application ID
# @return      0 if CLI verified, 1 if CLI not available
# @note        Returns 1 (not exit) to allow fallback to manual creation
# -----------------------------------------------------------------------------
verify_prism_cli() {
    print_progress "Verifying PrismLauncher CLI capabilities..."

    local prism_exec=""
    local help_output=""
    local exit_code=0

    # Determine the executable based on installation type
    if [[ "$CREATION_LAUNCHER_TYPE" == "flatpak" ]]; then
        prism_exec="flatpak run $PRISM_FLATPAK_ID"
        print_info "   → Testing Flatpak CLI..."

        help_output=$($prism_exec --help 2>&1)
        exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            print_warning "PrismLauncher Flatpak CLI test failed"
            print_info "Error output: $(echo "$help_output" | head -3)"
            return 1
        fi
    else
        # AppImage path
        local appimage="$CREATION_EXECUTABLE"

        chmod +x "$appimage" 2>/dev/null || true
        help_output=$("$appimage" --help 2>&1)
        exit_code=$?

        # Check if AppImage failed due to FUSE issues
        if [[ $exit_code -ne 0 ]] && echo "$help_output" | grep -q "FUSE\|Cannot mount\|squashfs\|Failed to open"; then
            print_warning "AppImage execution failed due to FUSE/squashfs issues"

            # Try extracting AppImage to avoid FUSE dependency
            print_progress "Attempting to extract AppImage contents..."
            cd "$CREATION_DATA_DIR"
            local extracted_path="$CREATION_DATA_DIR/squashfs-root/AppRun"
            if "$appimage" --appimage-extract >/dev/null 2>&1; then
                if [[ -d "$CREATION_DATA_DIR/squashfs-root" ]] && [[ -x "$extracted_path" ]]; then
                    print_success "AppImage extracted successfully"
                    CREATION_EXECUTABLE="$extracted_path"
                    prism_exec="$CREATION_EXECUTABLE"
                    help_output=$("$prism_exec" --help 2>&1)
                    exit_code=$?
                else
                    print_warning "AppImage extraction failed or incomplete"
                    print_info "Will skip CLI creation and use manual instance creation method"
                    return 1
                fi
            else
                print_warning "AppImage extraction failed"
                print_info "Will skip CLI creation and use manual instance creation method"
                return 1
            fi
        fi

        prism_exec="${PRISM_EXECUTABLE:-$appimage}"
    fi

    # Check if help command worked
    if [[ $exit_code -ne 0 ]]; then
        print_warning "PrismLauncher execution failed, using manual instance creation"
        print_info "Error output: $(echo "$help_output" | head -3)"
        return 1
    fi

    # Test for CLI support by checking help output
    if ! echo "$help_output" | grep -q -E "(cli|create|instance)"; then
        print_warning "PrismLauncher CLI may not support instance creation. Checking with --help-all..."

        local extended_help
        extended_help=$($prism_exec --help-all 2>&1)
        if ! echo "$extended_help" | grep -q -E "(cli|create-instance)"; then
            print_warning "This version of PrismLauncher does not support CLI instance creation"
            print_info "Will use manual instance creation method instead"
            return 1
        fi
    fi

    print_info "Available PrismLauncher CLI commands:"
    echo "$help_output" | grep -E "(create|instance|cli)" || echo "  (Basic CLI commands found)"
    print_success "PrismLauncher CLI instance creation verified ($CREATION_LAUNCHER_TYPE)"
    return 0
}

# -----------------------------------------------------------------------------
# @function    get_prism_executable
# @description Returns the PrismLauncher executable command or path from the
#              centralized path configuration.
#
# @param       None
# @global      CREATION_EXECUTABLE - (input) Executable path/command
# @stdout      Executable path or command
# @return      0 if executable set, 1 if not configured
# -----------------------------------------------------------------------------
get_prism_executable() {
    if [[ -n "$CREATION_EXECUTABLE" ]]; then
        echo "$CREATION_EXECUTABLE"
    else
        echo ""
        return 1
    fi
}
