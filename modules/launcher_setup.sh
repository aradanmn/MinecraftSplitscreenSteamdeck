#!/bin/bash
# =============================================================================
# LAUNCHER SETUP MODULE
# =============================================================================
# Version: 2.0.0
# Last Modified: 2026-01-23
# Source: https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# PrismLauncher setup and CLI verification functions
# PrismLauncher is used for automated instance creation via CLI
# It provides reliable Minecraft instance management and Fabric loader installation
#
# Supports both AppImage and Flatpak installations

# Track which PrismLauncher installation type is being used
PRISM_INSTALL_TYPE=""
PRISM_EXECUTABLE=""

# download_prism_launcher: Download or detect PrismLauncher
# Priority on immutable OS: 1) Existing Flatpak, 2) Install Flatpak, 3) Existing AppImage, 4) Download AppImage
# Priority on traditional OS: 1) Existing Flatpak, 2) Existing AppImage, 3) Download AppImage
# This function updates the centralized path configuration via set_creation_launcher_prismlauncher()
download_prism_launcher() {
    print_progress "Detecting PrismLauncher installation..."

    # Priority 1: Check for existing Flatpak installation
    # Use constants from path_configuration.sh
    if is_flatpak_installed "$PRISM_FLATPAK_ID" 2>/dev/null; then
        print_success "Found existing PrismLauncher Flatpak installation"

        # Ensure Flatpak data directory exists
        mkdir -p "$PRISM_FLATPAK_DATA_DIR/instances"

        # Update centralized path configuration
        set_creation_launcher_prismlauncher "flatpak" "flatpak run $PRISM_FLATPAK_ID"
        print_info "   → Using Flatpak data directory: $PRISM_FLATPAK_DATA_DIR"
        return 0
    fi

    # Priority 2 (immutable OS only): Install Flatpak if on immutable system
    if should_prefer_flatpak; then
        print_info "Detected immutable OS ($IMMUTABLE_OS_NAME) - preferring Flatpak installation"

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

                # Ensure Flatpak data directory exists
                mkdir -p "$PRISM_FLATPAK_DATA_DIR/instances"

                # Update centralized path configuration
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

        # Update centralized path configuration
        set_creation_launcher_prismlauncher "appimage" "$PRISM_APPIMAGE_PATH"
        return 0
    fi

    # Priority 4: Download AppImage
    print_progress "No existing PrismLauncher found - downloading AppImage..."

    # Create data directory
    mkdir -p "$PRISM_APPIMAGE_DATA_DIR"

    # Query GitHub API to get the latest release download URL
    # We specifically look for AppImage files matching the system architecture
    local prism_url
    local arch
    arch=$(uname -m)

    # Map architecture names (uname returns x86_64, aarch64, etc.)
    # AppImage naming: x86_64, aarch64
    prism_url=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest | \
        jq -r --arg arch "$arch" '.assets[] | select(.name | test("AppImage$")) | select(.name | contains($arch)) | .browser_download_url' | head -n1)

    # Validate that we got a valid download URL
    if [[ -z "$prism_url" || "$prism_url" == "null" ]]; then
        print_error "Could not find latest PrismLauncher AppImage URL."
        print_error "Please check https://github.com/PrismLauncher/PrismLauncher/releases manually."
        exit 1
    fi

    # Download and make executable
    wget -O "$PRISM_APPIMAGE_PATH" "$prism_url"
    chmod +x "$PRISM_APPIMAGE_PATH"

    # Update centralized path configuration
    set_creation_launcher_prismlauncher "appimage" "$PRISM_APPIMAGE_PATH"
    print_success "PrismLauncher AppImage downloaded successfully"
    print_info "   → Installation type: appimage"
}

# verify_prism_cli: Ensure PrismLauncher supports CLI operations
# We need CLI support for automated instance creation
# This function validates that the detected version has the required features
# Supports both AppImage and Flatpak installations
verify_prism_cli() {
    print_progress "Verifying PrismLauncher CLI capabilities..."

    local prism_exec=""
    local help_output=""
    local exit_code=0

    # Determine the executable based on installation type
    # Use centralized path configuration
    if [[ "$CREATION_LAUNCHER_TYPE" == "flatpak" ]]; then
        prism_exec="flatpak run $PRISM_FLATPAK_ID"
        print_info "   → Testing Flatpak CLI..."

        # Try to run Flatpak version
        help_output=$($prism_exec --help 2>&1)
        exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            print_warning "PrismLauncher Flatpak CLI test failed"
            print_info "Error output: $(echo "$help_output" | head -3)"
            return 1
        fi
    else
        # AppImage path - use centralized configuration
        local appimage="$CREATION_EXECUTABLE"

        # Ensure the AppImage is executable
        chmod +x "$appimage" 2>/dev/null || true

        # Try to run the AppImage to check CLI support
        help_output=$("$appimage" --help 2>&1)
        exit_code=$?

        # Check if AppImage failed due to FUSE issues or squashfs problems
        if [[ $exit_code -ne 0 ]] && echo "$help_output" | grep -q "FUSE\|Cannot mount\|squashfs\|Failed to open"; then
            print_warning "AppImage execution failed due to FUSE/squashfs issues"

            # Try extracting AppImage to avoid FUSE dependency
            print_progress "Attempting to extract AppImage contents..."
            cd "$CREATION_DATA_DIR"
            local extracted_path="$CREATION_DATA_DIR/squashfs-root/AppRun"
            if "$appimage" --appimage-extract >/dev/null 2>&1; then
                if [[ -d "$CREATION_DATA_DIR/squashfs-root" ]] && [[ -x "$extracted_path" ]]; then
                    print_success "AppImage extracted successfully"
                    # Update executable path in centralized config
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

    # Check if help command worked after potential extraction
    if [[ $exit_code -ne 0 ]]; then
        print_warning "PrismLauncher execution failed, using manual instance creation"
        print_info "Error output: $(echo "$help_output" | head -3)"
        return 1
    fi

    # Test for basic CLI support by checking help output
    # Look for keywords that indicate CLI instance creation is available
    if ! echo "$help_output" | grep -q -E "(cli|create|instance)"; then
        print_warning "PrismLauncher CLI may not support instance creation. Checking with --help-all..."

        # Fallback: try the extended help option
        local extended_help
        extended_help=$($prism_exec --help-all 2>&1)
        if ! echo "$extended_help" | grep -q -E "(cli|create-instance)"; then
            print_warning "This version of PrismLauncher does not support CLI instance creation"
            print_info "Will use manual instance creation method instead"
            return 1
        fi
    fi

    # Display available CLI commands for debugging purposes
    print_info "Available PrismLauncher CLI commands:"
    echo "$help_output" | grep -E "(create|instance|cli)" || echo "  (Basic CLI commands found)"
    print_success "PrismLauncher CLI instance creation verified ($CREATION_LAUNCHER_TYPE)"
    return 0
}

# get_prism_executable: Returns the PrismLauncher executable command
# This uses the centralized path configuration
get_prism_executable() {
    if [[ -n "$CREATION_EXECUTABLE" ]]; then
        echo "$CREATION_EXECUTABLE"
    else
        echo ""
        return 1
    fi
}
