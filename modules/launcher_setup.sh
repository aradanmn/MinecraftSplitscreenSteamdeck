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
# Priority: 1) Existing Flatpak, 2) Existing AppImage, 3) Download AppImage
download_prism_launcher() {
    print_progress "Detecting PrismLauncher installation..."

    # Priority 1: Check for existing Flatpak installation
    if is_flatpak_installed "${PRISM_FLATPAK_ID:-org.prismlauncher.PrismLauncher}" 2>/dev/null; then
        print_success "Found existing PrismLauncher Flatpak installation"
        PRISM_INSTALL_TYPE="flatpak"
        PRISM_EXECUTABLE="flatpak run ${PRISM_FLATPAK_ID:-org.prismlauncher.PrismLauncher}"
        export PRISM_INSTALL_TYPE PRISM_EXECUTABLE

        # Ensure Flatpak data directory exists
        local flatpak_data_dir="${PRISM_FLATPAK_DATA_DIR:-$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher}"
        mkdir -p "$flatpak_data_dir/instances"

        # Update TARGET_DIR to use Flatpak data directory for this session
        # Note: This affects where instances are created
        print_info "   → Using Flatpak data directory: $flatpak_data_dir"
        return 0
    fi

    # Priority 2: Check for existing AppImage
    if [[ -f "$TARGET_DIR/PrismLauncher.AppImage" ]]; then
        print_success "PrismLauncher AppImage already present"
        PRISM_INSTALL_TYPE="appimage"
        PRISM_EXECUTABLE="$TARGET_DIR/PrismLauncher.AppImage"
        export PRISM_INSTALL_TYPE PRISM_EXECUTABLE
        return 0
    fi

    # Priority 3: Download AppImage
    print_progress "No existing PrismLauncher found - downloading AppImage..."
    PRISM_INSTALL_TYPE="appimage"

    # Query GitHub API to get the latest release download URL
    # We specifically look for AppImage files in the release assets
    local prism_url
    prism_url=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest | \
        jq -r '.assets[] | select(.name | test("AppImage$")) | .browser_download_url' | head -n1)

    # Validate that we got a valid download URL
    if [[ -z "$prism_url" || "$prism_url" == "null" ]]; then
        print_error "Could not find latest PrismLauncher AppImage URL."
        print_error "Please check https://github.com/PrismLauncher/PrismLauncher/releases manually."
        exit 1
    fi

    # Download and make executable
    wget -O "$TARGET_DIR/PrismLauncher.AppImage" "$prism_url"
    chmod +x "$TARGET_DIR/PrismLauncher.AppImage"
    PRISM_EXECUTABLE="$TARGET_DIR/PrismLauncher.AppImage"
    export PRISM_INSTALL_TYPE PRISM_EXECUTABLE
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
    if [[ "$PRISM_INSTALL_TYPE" == "flatpak" ]]; then
        prism_exec="flatpak run ${PRISM_FLATPAK_ID:-org.prismlauncher.PrismLauncher}"
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
        # AppImage path
        local appimage="${PRISM_EXECUTABLE:-$TARGET_DIR/PrismLauncher.AppImage}"

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
            cd "$TARGET_DIR"
            if "$appimage" --appimage-extract >/dev/null 2>&1; then
                if [[ -d "$TARGET_DIR/squashfs-root" ]] && [[ -x "$TARGET_DIR/squashfs-root/AppRun" ]]; then
                    print_success "AppImage extracted successfully"
                    # Update executable path to point to extracted version
                    PRISM_EXECUTABLE="$TARGET_DIR/squashfs-root/AppRun"
                    export PRISM_EXECUTABLE
                    prism_exec="$PRISM_EXECUTABLE"
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
    print_success "PrismLauncher CLI instance creation verified ($PRISM_INSTALL_TYPE)"
    return 0
}

# get_prism_executable: Returns the PrismLauncher executable command
# This handles both AppImage (direct path) and Flatpak (flatpak run command)
get_prism_executable() {
    if [[ -n "$PRISM_EXECUTABLE" ]]; then
        echo "$PRISM_EXECUTABLE"
    elif [[ "$PRISM_INSTALL_TYPE" == "flatpak" ]]; then
        echo "flatpak run ${PRISM_FLATPAK_ID:-org.prismlauncher.PrismLauncher}"
    elif [[ -x "$TARGET_DIR/squashfs-root/AppRun" ]]; then
        echo "$TARGET_DIR/squashfs-root/AppRun"
    elif [[ -x "$TARGET_DIR/PrismLauncher.AppImage" ]]; then
        echo "$TARGET_DIR/PrismLauncher.AppImage"
    else
        echo ""
        return 1
    fi
}
