#!/bin/bash
# =============================================================================
# POLLYMC SETUP MODULE
# =============================================================================
# @file        pollymc_setup.sh
# @version     2.1.0
# @date        2026-01-31
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Handles the setup and optimization of PollyMC as the primary launcher for
#   splitscreen gameplay. PollyMC provides better offline support and handling
#   of multiple simultaneous instances compared to PrismLauncher.
#
#   Note: As of 2026-01, the PollyMC GitHub repository (fn2006/PollyMC) is no
#   longer available. This module will attempt to download but gracefully falls
#   back to PrismLauncher when the download fails.
#
#   PollyMC advantages for splitscreen:
#   - No forced Microsoft login requirements (offline-friendly)
#   - Better handling of multiple simultaneous instances
#   - Cleaner interface without authentication popups
#   - More stable for automated controller-based launching
#
# @dependencies
#   - wget (for downloading AppImage)
#   - rsync (for instance migration)
#   - jq (optional, for account merging)
#   - file (for download validation)
#   - utilities.sh (for print_* functions, merge_accounts_json)
#   - path_configuration.sh (for path constants, setters, and PREFER_FLATPAK)
#
# @exports
#   Functions:
#     - setup_pollymc          : Main setup function
#     - setup_pollymc_launcher : Prepare for launcher script generation (deprecated)
#     - cleanup_prism_launcher : Remove PrismLauncher after successful setup
#
# @changelog
#   2.1.0 (2026-01-31) - Added architecture-aware AppImage download (x86_64/arm64)
#   2.0.3 (2026-01-31) - Fix: Add --system flag to avoid flatpak remote selection prompt
#   2.0.2 (2026-01-25) - Fix: Try system-level Flatpak install first, then user-level
#   2.0.1 (2026-01-25) - Fix: Only create directories after successful download/install
#   2.0.0 (2026-01-25) - Rebased to 2.x for fork; added Flatpak installation for immutable OS
#   1.2.0 (2026-01-24) - Added proper fallback handling, empty dir cleanup
#   1.1.0 (2026-01-23) - Added instance migration with options.txt preservation
#   1.0.0 (2026-01-22) - Initial version
# =============================================================================

# -----------------------------------------------------------------------------
# @function    setup_pollymc
# @description Main function to configure PollyMC as the primary launcher for
#              splitscreen gameplay. Handles detection, download, instance
#              migration, account configuration, and verification.
#
#              Process:
#              1. Detect or download PollyMC (Flatpak/AppImage)
#              2. Migrate instances from PrismLauncher to PollyMC
#              3. Merge offline accounts configuration
#              4. Configure PollyMC to skip setup wizard
#              5. Verify PollyMC compatibility
#              6. Clean up PrismLauncher if successful
#
#              Falls back to PrismLauncher if any step fails.
#
# @param       None
# @global      PREFER_FLATPAK          - (input) Whether to prefer Flatpak (from path_configuration)
# @global      POLLYMC_FLATPAK_ID      - (input) PollyMC Flatpak ID
# @global      POLLYMC_APPIMAGE_PATH   - (input) Expected AppImage location
# @global      CREATION_INSTANCES_DIR  - (input) Source instances directory
# @global      CREATION_DATA_DIR       - (input) PrismLauncher data directory
# @global      ACTIVE_*                - (output) Updated via set_active_launcher_pollymc
# @global      JAVA_PATH               - (input) Java executable path for config
# @return      0 always (failures handled internally with fallback)
# -----------------------------------------------------------------------------
setup_pollymc() {
    print_header "SETTING UP POLLYMC"

    print_progress "Detecting PollyMC installation method..."

    local pollymc_type=""
    local pollymc_data_dir=""
    local pollymc_executable=""

    # Priority 1: Check for existing Flatpak installation
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID" 2>/dev/null; then
        print_success "Found existing PollyMC Flatpak installation"
        pollymc_type="flatpak"
        pollymc_data_dir="$POLLYMC_FLATPAK_DATA_DIR"
        pollymc_executable="flatpak run $POLLYMC_FLATPAK_ID"

        mkdir -p "$pollymc_data_dir/instances"
        print_info "   -> Using Flatpak data directory: $pollymc_data_dir"

    # Priority 2: Check for existing AppImage
    elif [[ -x "$POLLYMC_APPIMAGE_PATH" ]]; then
        print_success "Found existing PollyMC AppImage"
        pollymc_type="appimage"
        pollymc_data_dir="$POLLYMC_APPIMAGE_DATA_DIR"
        pollymc_executable="$POLLYMC_APPIMAGE_PATH"
        print_info "   -> Using existing AppImage: $POLLYMC_APPIMAGE_PATH"

    # Priority 3 (immutable OS only): Install Flatpak if preferred
    # PREFER_FLATPAK is set by configure_launcher_paths() in path_configuration.sh
    elif [[ "$PREFER_FLATPAK" == true ]]; then
        print_info "Immutable OS detected - preferring Flatpak installation for PollyMC"

        if command -v flatpak &>/dev/null; then
            print_progress "Installing PollyMC via Flatpak..."

            local flatpak_installed=false

            # Try system-level install first (works on Bazzite/SteamOS where Flathub is system-only)
            # Use --system explicitly to avoid flatpak's remote selection prompt when both system
            # and user flathub remotes exist
            if flatpak install --system -y flathub "$POLLYMC_FLATPAK_ID" 2>/dev/null; then
                flatpak_installed=true
                print_success "PollyMC Flatpak installed (system)"
            else
                # Fall back to user-level install
                # First ensure Flathub repo is available for user
                if ! flatpak remote-list --user 2>/dev/null | grep -q flathub; then
                    print_progress "Adding Flathub repository for user..."
                    flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
                fi

                if flatpak install --user -y flathub "$POLLYMC_FLATPAK_ID" 2>/dev/null; then
                    flatpak_installed=true
                    print_success "PollyMC Flatpak installed (user)"
                fi
            fi

            if [[ "$flatpak_installed" == true ]]; then
                pollymc_type="flatpak"
                pollymc_data_dir="$POLLYMC_FLATPAK_DATA_DIR"
                pollymc_executable="flatpak run $POLLYMC_FLATPAK_ID"

                mkdir -p "$pollymc_data_dir/instances"
                print_info "   -> Using Flatpak data directory: $pollymc_data_dir"
            else
                print_warning "PollyMC Flatpak installation failed - falling back to AppImage download"
                # Fall through to AppImage download below
            fi
        else
            print_warning "Flatpak not available - falling back to AppImage download"
        fi
    fi

    # Priority 4: Download AppImage (fallback for traditional OS or if Flatpak install failed)
    if [[ -z "$pollymc_type" ]]; then
        print_progress "No existing PollyMC found - downloading AppImage..."

        # Detect system architecture for correct AppImage download
        local arch arch_suffix
        arch=$(uname -m)
        case "$arch" in
            x86_64)
                arch_suffix="x86_64"
                ;;
            aarch64|arm64)
                arch_suffix="arm64"
                ;;
            *)
                print_warning "Unknown architecture: $arch - trying x86_64"
                arch_suffix="x86_64"
                ;;
        esac

        local pollymc_url="https://github.com/fn2006/PollyMC/releases/latest/download/PollyMC-Linux-${arch_suffix}.AppImage"
        print_progress "Fetching PollyMC from GitHub releases: $(basename "$pollymc_url")..."

        # Download to temp location first, only create directory on success
        local temp_appimage
        temp_appimage=$(mktemp)

        # Download with fallback handling
        if ! wget -q -O "$temp_appimage" "$pollymc_url"; then
            print_warning "PollyMC download failed - continuing with PrismLauncher as primary launcher"
            print_info "   This is not a critical error - PrismLauncher works fine for splitscreen"
            rm -f "$temp_appimage" 2>/dev/null
            return 0
        fi

        # Verify downloaded file is valid
        if [[ ! -s "$temp_appimage" ]] || file "$temp_appimage" | grep -q "HTML\|text"; then
            print_warning "PollyMC download produced invalid file - continuing with PrismLauncher"
            rm -f "$temp_appimage" 2>/dev/null
            return 0
        fi

        # Download successful - now create directory and move file
        pollymc_type="appimage"
        pollymc_data_dir="$POLLYMC_APPIMAGE_DATA_DIR"
        mkdir -p "$pollymc_data_dir"
        mv "$temp_appimage" "$POLLYMC_APPIMAGE_PATH"
        chmod +x "$POLLYMC_APPIMAGE_PATH"
        pollymc_executable="$POLLYMC_APPIMAGE_PATH"
        print_success "PollyMC AppImage downloaded and configured successfully"
    fi

    # Update centralized path configuration
    set_active_launcher_pollymc "$pollymc_type" "$pollymc_executable"

    print_info "   -> PollyMC installation type: $pollymc_type"
    print_info "   -> Active data directory: $ACTIVE_DATA_DIR"

    # =========================================================================
    # Instance Migration
    # =========================================================================
    _migrate_instances_to_pollymc

    # =========================================================================
    # Account Configuration Migration
    # =========================================================================
    _migrate_accounts_to_pollymc

    # =========================================================================
    # PollyMC Configuration
    # =========================================================================
    _configure_pollymc_settings

    # =========================================================================
    # Compatibility Verification
    # =========================================================================
    _verify_pollymc_and_finalize
}

# -----------------------------------------------------------------------------
# @function    _migrate_instances_to_pollymc
# @description Internal function to migrate Minecraft instances from
#              PrismLauncher to PollyMC, preserving options.txt settings.
# @param       None
# @global      CREATION_INSTANCES_DIR - (input) Source directory
# @global      ACTIVE_INSTANCES_DIR   - (input) Destination directory
# @global      ACTIVE_DATA_DIR        - (input) For backup directory
# @return      0 always
# -----------------------------------------------------------------------------
_migrate_instances_to_pollymc() {
    print_progress "Migrating PrismLauncher instances to PollyMC data directory..."

    local source_instances="$CREATION_INSTANCES_DIR"
    local dest_instances="$ACTIVE_INSTANCES_DIR"

    if [[ -d "$source_instances" ]] && [[ "$source_instances" != "$dest_instances" ]]; then
        mkdir -p "$dest_instances"

        # Preserve options.txt during update
        for i in {1..4}; do
            local instance_name="latestUpdate-$i"
            local instance_path="$dest_instances/$instance_name"
            local options_file="$instance_path/.minecraft/options.txt"

            if [[ -d "$instance_path" ]]; then
                print_info "   -> Updating $instance_name while preserving settings"

                if [[ -f "$options_file" ]]; then
                    print_info "     -> Preserving existing options.txt for $instance_name"
                    local backup_dir="$ACTIVE_DATA_DIR/options_backup"
                    mkdir -p "$backup_dir"
                    cp "$options_file" "$backup_dir/${instance_name}_options.txt"
                fi

                rm -rf "$instance_path"
            fi
        done

        # Copy instances excluding options.txt
        rsync -a --exclude='*.minecraft/options.txt' "$source_instances/"* "$dest_instances/"

        # Restore options.txt files
        local backup_dir="$ACTIVE_DATA_DIR/options_backup"
        for i in {1..4}; do
            local instance_name="latestUpdate-$i"
            local instance_path="$dest_instances/$instance_name"
            local options_file="$instance_path/.minecraft/options.txt"
            local backup_file="$backup_dir/${instance_name}_options.txt"

            if [[ -f "$backup_file" ]]; then
                print_info "   -> Restoring saved options.txt for $instance_name"
                mkdir -p "$(dirname "$options_file")"
                cp "$backup_file" "$options_file"
            fi
        done

        print_success "Splitscreen instances migrated to PollyMC"

        [[ -d "$backup_dir" ]] && rm -rf "$backup_dir"

        local instance_count
        instance_count=$(find "$dest_instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
        print_info "   -> $instance_count splitscreen instances available in PollyMC"
    elif [[ "$source_instances" == "$dest_instances" ]]; then
        print_info "   -> Instances already in correct location, no migration needed"
    else
        print_warning "No instances directory found to migrate"
    fi
}

# -----------------------------------------------------------------------------
# @function    _migrate_accounts_to_pollymc
# @description Internal function to merge splitscreen accounts (P1-P4) into
#              PollyMC's accounts.json while preserving existing accounts.
# @param       None
# @global      CREATION_DATA_DIR - (input) Source accounts location
# @global      ACTIVE_DATA_DIR   - (input) Destination accounts location
# @return      0 always
# -----------------------------------------------------------------------------
_migrate_accounts_to_pollymc() {
    local source_accounts="$CREATION_DATA_DIR/accounts.json"
    local dest_accounts="$ACTIVE_DATA_DIR/accounts.json"

    if [[ -f "$source_accounts" ]] && [[ "$source_accounts" != "$dest_accounts" ]]; then
        if merge_accounts_json "$source_accounts" "$dest_accounts"; then
            print_success "Offline splitscreen accounts merged into PollyMC"
            print_info "   -> Player accounts P1, P2, P3, P4 configured for offline gameplay"
            if command -v jq >/dev/null 2>&1; then
                local existing_count
                existing_count=$(jq '.accounts | map(select(.profile.name | test("^P[1-4]$") | not)) | length' "$dest_accounts" 2>/dev/null || echo "0")
                if [[ "$existing_count" -gt 0 ]]; then
                    print_info "   -> Preserved $existing_count existing account(s)"
                fi
            fi
        fi
    elif [[ -f "$dest_accounts" ]]; then
        print_info "   -> Accounts already configured in PollyMC"
    else
        print_warning "accounts.json not found - splitscreen accounts may need manual setup"
    fi
}

# -----------------------------------------------------------------------------
# @function    _configure_pollymc_settings
# @description Internal function to create PollyMC configuration file that
#              skips the setup wizard and sets Java/memory defaults.
# @param       None
# @global      ACTIVE_DATA_DIR - (input) Where to write pollymc.cfg
# @global      JAVA_PATH       - (input) Java executable path
# @return      0 always
# -----------------------------------------------------------------------------
_configure_pollymc_settings() {
    print_progress "Configuring PollyMC with proven working settings..."

    local current_hostname
    if command -v hostname >/dev/null 2>&1; then
        current_hostname=$(hostname)
    elif [[ -r /proc/sys/kernel/hostname ]]; then
        current_hostname=$(cat /proc/sys/kernel/hostname)
    elif [[ -n "$HOSTNAME" ]]; then
        current_hostname="$HOSTNAME"
    else
        current_hostname="localhost"
    fi

    cat > "$ACTIVE_DATA_DIR/pollymc.cfg" <<EOF
[General]
ApplicationTheme=system
ConfigVersion=1.2
FlameKeyOverride=\$2a\$10\$bL4bIL5pUWqfcO7KQtnMReakwtfHbNKh6v1uTpKlzhwoueEJQnPnm
FlameKeyShouldBeFetchedOnStartup=false
IconTheme=pe_colored
JavaPath=${JAVA_PATH}
Language=en_US
LastHostname=${current_hostname}
MainWindowGeometry=@ByteArray(AdnQywADAAAAAAwwAAAAzAAAD08AAANIAAAMMAAAAPEAAA9PAAADSAAAAAEAAAAAB4AAAAwwAAAA8QAAD08AAANI)
MainWindowState="@ByteArray(AAAA/wAAAAD9AAAAAAAAApUAAAH8AAAABAAAAAQAAAAIAAAACPwAAAADAAAAAQAAAAEAAAAeAGkAbgBzAHQAYQBuAGMAZQBUAG8AbwBsAEIAYQByAwAAAAD/////AAAAAAAAAAAAAAACAAAAAQAAABYAbQBhAGkAbgBUAG8AbwBsAEIAYQByAQAAAAD/////AAAAAAAAAAAAAAADAAAAAQAAABYAbgBlAHcAcwBUAG8AbwBsAEIAYQByAQAAAAD/////AAAAAAAAAAA=)"
MaxMemAlloc=4096
MinMemAlloc=512
ToolbarsLocked=false
WideBarVisibility_instanceToolBar="@ByteArray(111111111,BpBQWIumr+0ABXFEarV0R5nU0iY=)"
EOF

    print_success "PollyMC configured to skip setup wizard"
    print_info "   -> Setup wizard will not appear on first launch"
    print_info "   -> Java path and memory settings pre-configured"
}

# -----------------------------------------------------------------------------
# @function    _verify_pollymc_and_finalize
# @description Internal function to verify PollyMC works and finalize setup.
#              Reverts to PrismLauncher if verification fails.
# @param       None
# @global      ACTIVE_LAUNCHER_TYPE   - (input) "appimage" or "flatpak"
# @global      POLLYMC_FLATPAK_ID     - (input) Flatpak ID for testing
# @global      POLLYMC_APPIMAGE_PATH  - (input) AppImage path for testing
# @global      ACTIVE_INSTANCES_DIR   - (input) For instance verification
# @global      CREATION_DATA_DIR      - (input) For cleanup comparison
# @global      ACTIVE_DATA_DIR        - (input) For cleanup comparison
# @return      0 always
# -----------------------------------------------------------------------------
_verify_pollymc_and_finalize() {
    print_progress "Testing PollyMC compatibility and basic functionality..."

    local pollymc_test_passed=false

    if [[ "$ACTIVE_LAUNCHER_TYPE" == "flatpak" ]]; then
        if flatpak run "$POLLYMC_FLATPAK_ID" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "PollyMC Flatpak compatibility test passed"
        fi
    else
        if timeout 5s "$POLLYMC_APPIMAGE_PATH" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "PollyMC AppImage compatibility test passed"
        fi
    fi

    if [[ "$pollymc_test_passed" == true ]]; then
        print_progress "Verifying PollyMC can access splitscreen instances..."
        local polly_instances_count
        polly_instances_count=$(find "$ACTIVE_INSTANCES_DIR" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)

        if [[ "$polly_instances_count" -eq 4 ]]; then
            print_success "PollyMC instance verification successful - all 4 instances accessible"
            print_info "   -> latestUpdate-1, latestUpdate-2, latestUpdate-3, latestUpdate-4 ready"

            setup_pollymc_launcher

            if [[ "$CREATION_DATA_DIR" != "$ACTIVE_DATA_DIR" ]]; then
                cleanup_prism_launcher
            fi

            print_success "PollyMC is now the primary launcher for splitscreen gameplay"
            print_info "   -> Installation type: $ACTIVE_LAUNCHER_TYPE"
        else
            print_warning "PollyMC instance verification failed - found $polly_instances_count instances instead of 4"
            print_info "   -> Falling back to PrismLauncher as primary launcher"
            revert_to_prismlauncher
        fi
    else
        print_warning "PollyMC compatibility test failed"
        print_info "   -> This may be due to system restrictions or missing dependencies"
        print_info "   -> Falling back to PrismLauncher for gameplay (still fully functional)"
        revert_to_prismlauncher
    fi
}

# -----------------------------------------------------------------------------
# @function    setup_pollymc_launcher
# @description Prepares PollyMC for launcher script generation. This function
#              is now mostly a placeholder as the actual script generation
#              happens in generate_launcher_script() in main_workflow.sh.
#
# @deprecated  Use generate_launcher_script() instead
# @param       None
# @return      0 always
# -----------------------------------------------------------------------------
setup_pollymc_launcher() {
    print_progress "Preparing PollyMC for launcher script generation..."
    print_info "Launcher script will be generated in the next phase with correct paths"
    print_success "PollyMC configured for launcher script generation"
}

# -----------------------------------------------------------------------------
# @function    cleanup_prism_launcher
# @description Removes PrismLauncher installation after successful PollyMC
#              setup to save disk space. Includes safety checks to prevent
#              accidental deletion of important directories.
#
# @param       None
# @global      CREATION_DATA_DIR - (input) PrismLauncher data directory to remove
# @return      0 on success, 1 if cd fails
# @note        Only removes directories containing "PrismLauncher" in the path
# -----------------------------------------------------------------------------
cleanup_prism_launcher() {
    print_progress "Cleaning up PrismLauncher (no longer needed)..."

    # Safety: Navigate to home directory first
    cd "$HOME" || return 1

    local prism_dir="$CREATION_DATA_DIR"

    # Safety checks before removal
    if [[ -d "$prism_dir" && "$prism_dir" != "$HOME" && "$prism_dir" != "/" && "$prism_dir" == *"PrismLauncher"* ]]; then
        rm -rf "$prism_dir"
        print_success "Removed PrismLauncher directory: $prism_dir"
        print_info "All essential files now in PollyMC directory"
    else
        print_info "Skipped directory removal (not a PrismLauncher directory): $prism_dir"
    fi
}
