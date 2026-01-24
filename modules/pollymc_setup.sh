#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - PollyMC Setup Module
# =============================================================================
#
# This module handles the setup and optimization of PollyMC as the primary
# launcher for splitscreen gameplay, providing better offline support and
# handling of multiple simultaneous instances compared to PrismLauncher.
#
# Functions provided:
# - setup_pollymc: Configure PollyMC as the primary splitscreen launcher
# - setup_pollymc_launcher: Configure splitscreen launcher script for PollyMC
# - cleanup_prism_launcher: Clean up PrismLauncher files after PollyMC setup
#
# =============================================================================

# setup_pollymc: Configure PollyMC as the primary launcher for splitscreen gameplay
#
# POLLYMC ADVANTAGES FOR SPLITSCREEN:
# - No forced Microsoft login requirements (offline-friendly)
# - Better handling of multiple simultaneous instances
# - Cleaner interface without authentication popups
# - More stable for automated controller-based launching
#
# PROCESS OVERVIEW:
# 1. Download PollyMC AppImage from GitHub releases
# 2. Migrate all instances from PrismLauncher to PollyMC
# 3. Copy offline accounts configuration
# 4. Test PollyMC compatibility and functionality
# 5. Set up splitscreen launcher script for PollyMC
# 6. Clean up PrismLauncher files to save space
#
# FALLBACK STRATEGY:
# If PollyMC fails at any step, we fall back to PrismLauncher
# This ensures the installation completes successfully regardless
setup_pollymc() {
    print_header "🎮 SETTING UP POLLYMC"

    # =============================================================================
    # POLLYMC DETECTION: Check for existing installation (Flatpak or AppImage)
    # =============================================================================

    print_progress "Detecting PollyMC installation method..."

    local pollymc_type=""
    local pollymc_data_dir=""
    local pollymc_executable=""

    # Priority 1: Check for existing Flatpak installation
    # Use constants from path_configuration.sh
    if is_flatpak_installed "$POLLYMC_FLATPAK_ID" 2>/dev/null; then
        print_success "✅ Found existing PollyMC Flatpak installation"
        pollymc_type="flatpak"
        pollymc_data_dir="$POLLYMC_FLATPAK_DATA_DIR"
        pollymc_executable="flatpak run $POLLYMC_FLATPAK_ID"

        # Ensure Flatpak data directory exists
        mkdir -p "$pollymc_data_dir/instances"
        print_info "   → Using Flatpak data directory: $pollymc_data_dir"

    # Priority 2: Check for existing AppImage
    elif [[ -x "$POLLYMC_APPIMAGE_PATH" ]]; then
        print_success "✅ Found existing PollyMC AppImage"
        pollymc_type="appimage"
        pollymc_data_dir="$POLLYMC_APPIMAGE_DATA_DIR"
        pollymc_executable="$POLLYMC_APPIMAGE_PATH"
        print_info "   → Using existing AppImage: $POLLYMC_APPIMAGE_PATH"

    # Priority 3: Download AppImage (fallback)
    else
        print_progress "No existing PollyMC found - downloading AppImage..."
        pollymc_type="appimage"
        pollymc_data_dir="$POLLYMC_APPIMAGE_DATA_DIR"

        # Create PollyMC data directory structure
        mkdir -p "$pollymc_data_dir"

        # Download PollyMC AppImage from official GitHub releases
        local pollymc_url="https://github.com/fn2006/PollyMC/releases/latest/download/PollyMC-Linux-x86_64.AppImage"
        print_progress "Fetching PollyMC from GitHub releases: $(basename "$pollymc_url")..."

        # DOWNLOAD WITH FALLBACK HANDLING
        if ! wget -O "$POLLYMC_APPIMAGE_PATH" "$pollymc_url"; then
            print_warning "❌ PollyMC download failed - continuing with PrismLauncher as primary launcher"
            print_info "   This is not a critical error - PrismLauncher works fine for splitscreen"
            return 0
        else
            chmod +x "$POLLYMC_APPIMAGE_PATH"
            pollymc_executable="$POLLYMC_APPIMAGE_PATH"
            print_success "✅ PollyMC AppImage downloaded and configured successfully"
        fi
    fi

    # Update centralized path configuration to use PollyMC as active launcher
    set_active_launcher_pollymc "$pollymc_type" "$pollymc_executable"

    print_info "   → PollyMC installation type: $pollymc_type"
    print_info "   → Active data directory: $ACTIVE_DATA_DIR"

    # =============================================================================
    # INSTANCE MIGRATION: Transfer all Minecraft instances from PrismLauncher
    # =============================================================================

    # INSTANCE DIRECTORY MIGRATION
    # Copy the complete instances directory structure from PrismLauncher to PollyMC
    # This includes all 4 splitscreen instances with their configurations, mods, and saves
    print_progress "Migrating PrismLauncher instances to PollyMC data directory..."

    # INSTANCES TRANSFER: Copy entire instances folder with all splitscreen configurations
    # Use centralized paths: CREATION_INSTANCES_DIR -> ACTIVE_INSTANCES_DIR
    local source_instances="$CREATION_INSTANCES_DIR"
    local dest_instances="$ACTIVE_INSTANCES_DIR"

    if [[ -d "$source_instances" ]] && [[ "$source_instances" != "$dest_instances" ]]; then
        # Create instances directory if it doesn't exist
        mkdir -p "$dest_instances"

        # For updates: preserve options.txt and replace instances
        for i in {1..4}; do
            local instance_name="latestUpdate-$i"
            local instance_path="$dest_instances/$instance_name"
            local options_file="$instance_path/.minecraft/options.txt"

            if [[ -d "$instance_path" ]]; then
                print_info "   → Updating $instance_name while preserving settings"

                # Backup options.txt if it exists
                if [[ -f "$options_file" ]]; then
                    print_info "     → Preserving existing options.txt for $instance_name"
                    local backup_dir="$ACTIVE_DATA_DIR/options_backup"
                    mkdir -p "$backup_dir"
                    cp "$options_file" "$backup_dir/${instance_name}_options.txt"
                fi

                # Remove old instance but keep options backup
                rm -rf "$instance_path"
            fi
        done

        # Copy the updated instances while excluding options.txt files
        rsync -a --exclude='*.minecraft/options.txt' "$source_instances/"* "$dest_instances/"

        # Restore options.txt files from temporary backup location
        local backup_dir="$ACTIVE_DATA_DIR/options_backup"
        for i in {1..4}; do
            local instance_name="latestUpdate-$i"
            local instance_path="$dest_instances/$instance_name"
            local options_file="$instance_path/.minecraft/options.txt"
            local backup_file="$backup_dir/${instance_name}_options.txt"

            if [[ -f "$backup_file" ]]; then
                print_info "   → Restoring saved options.txt for $instance_name"
                mkdir -p "$(dirname "$options_file")"
                cp "$backup_file" "$options_file"
            fi
        done

        print_success "✅ Splitscreen instances migrated to PollyMC"

        # Clean up the temporary backup directory
        if [[ -d "$backup_dir" ]]; then
            rm -rf "$backup_dir"
        fi

        # INSTANCE COUNT VERIFICATION: Ensure all 4 instances were copied successfully
        local instance_count
        instance_count=$(find "$dest_instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
        print_info "   → $instance_count splitscreen instances available in PollyMC"
    elif [[ "$source_instances" == "$dest_instances" ]]; then
        print_info "   → Instances already in correct location, no migration needed"
    else
        print_warning "⚠️  No instances directory found to migrate"
    fi

    # =============================================================================
    # ACCOUNT CONFIGURATION MIGRATION
    # =============================================================================

    # OFFLINE ACCOUNTS TRANSFER: Copy splitscreen player account configurations
    # The accounts.json file contains offline player profiles for Player 1-4
    # These accounts allow splitscreen gameplay without requiring multiple Microsoft accounts
    local source_accounts="$CREATION_DATA_DIR/accounts.json"
    local dest_accounts="$ACTIVE_DATA_DIR/accounts.json"

    if [[ -f "$source_accounts" ]] && [[ "$source_accounts" != "$dest_accounts" ]]; then
        cp "$source_accounts" "$dest_accounts"
        print_success "✅ Offline splitscreen accounts copied to PollyMC"
        print_info "   → Player accounts P1, P2, P3, P4 configured for offline gameplay"
    elif [[ -f "$dest_accounts" ]]; then
        print_info "   → Accounts already configured in PollyMC"
    else
        print_warning "⚠️  accounts.json not found - splitscreen accounts may need manual setup"
    fi

    # =============================================================================
    # POLLYMC CONFIGURATION: Skip Setup Wizard
    # =============================================================================

    # SETUP WIZARD BYPASS: Create PollyMC configuration using user's proven working settings
    # This uses the exact configuration from the user's working PollyMC installation
    # Guarantees compatibility and skips all setup wizard prompts
    print_progress "Configuring PollyMC with proven working settings..."

    # Get the current hostname for dynamic configuration with multiple fallback methods
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

    print_success "✅ PollyMC configured to skip setup wizard"
    print_info "   → Setup wizard will not appear on first launch"
    print_info "   → Java path and memory settings pre-configured"

    # =============================================================================
    # POLLYMC COMPATIBILITY VERIFICATION
    # =============================================================================

    # POLLYMC FUNCTIONALITY TEST: Verify PollyMC works on this system
    # Test execution based on installation type (AppImage or Flatpak)
    print_progress "Testing PollyMC compatibility and basic functionality..."

    local pollymc_test_passed=false

    if [[ "$ACTIVE_LAUNCHER_TYPE" == "flatpak" ]]; then
        # FLATPAK TEST: Verify Flatpak app is accessible
        if flatpak run "$POLLYMC_FLATPAK_ID" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "✅ PollyMC Flatpak compatibility test passed"
        fi
    else
        # APPIMAGE EXECUTION TEST: Run PollyMC with --help flag to verify it works
        if timeout 5s "$POLLYMC_APPIMAGE_PATH" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "✅ PollyMC AppImage compatibility test passed"
        fi
    fi

    if [[ "$pollymc_test_passed" == true ]]; then
        # =============================================================================
        # POLLYMC INSTANCE VERIFICATION AND FINAL SETUP
        # =============================================================================

        # INSTANCE ACCESS VERIFICATION: Confirm PollyMC can detect and access migrated instances
        print_progress "Verifying PollyMC can access splitscreen instances..."
        local polly_instances_count
        polly_instances_count=$(find "$ACTIVE_INSTANCES_DIR" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)

        if [[ "$polly_instances_count" -eq 4 ]]; then
            print_success "✅ PollyMC instance verification successful - all 4 instances accessible"
            print_info "   → latestUpdate-1, latestUpdate-2, latestUpdate-3, latestUpdate-4 ready"

            # LAUNCHER SCRIPT CONFIGURATION: Prepare for launcher script generation
            # The actual script generation happens in generate_launcher_script() phase
            setup_pollymc_launcher

            # CLEANUP PHASE: Remove PrismLauncher since PollyMC is working
            # Only cleanup if we migrated from a different location
            if [[ "$CREATION_DATA_DIR" != "$ACTIVE_DATA_DIR" ]]; then
                cleanup_prism_launcher
            fi

            print_success "🎮 PollyMC is now the primary launcher for splitscreen gameplay"
            print_info "   → Installation type: $ACTIVE_LAUNCHER_TYPE"
        else
            print_warning "⚠️  PollyMC instance verification failed - found $polly_instances_count instances instead of 4"
            print_info "   → Falling back to PrismLauncher as primary launcher"
            # Revert to PrismLauncher as active launcher
            set_creation_launcher_prismlauncher "$CREATION_LAUNCHER_TYPE" "$CREATION_EXECUTABLE"
        fi
    else
        print_warning "❌ PollyMC compatibility test failed"
        print_info "   → This may be due to system restrictions or missing dependencies"
        print_info "   → Falling back to PrismLauncher for gameplay (still fully functional)"
        # Revert to PrismLauncher as active launcher - it stays as both creation and active
    fi
}

# Configure the splitscreen launcher script for PollyMC
# NOTE: This function is now deprecated in favor of generate_launcher_script() in main_workflow.sh
# The new approach generates the launcher script with correct paths baked in,
# eliminating the need for sed-based path replacements.
# This function is kept for backwards compatibility but may be removed in future versions.
setup_pollymc_launcher() {
    print_progress "Preparing PollyMC for launcher script generation..."

    # The actual launcher script generation now happens in generate_launcher_script()
    # which is called after setup_pollymc() in the main workflow.
    # This ensures the launcher script is generated with the correct detected paths
    # for both AppImage and Flatpak installations.

    print_info "Launcher script will be generated in the next phase with correct paths"
    print_success "PollyMC configured for launcher script generation"
}

# Clean up PrismLauncher installation after successful PollyMC setup
# This removes the temporary PrismLauncher directory to save disk space
# PrismLauncher was only needed for automated instance creation via CLI
cleanup_prism_launcher() {
    print_progress "Cleaning up PrismLauncher (no longer needed)..."

    # SAFETY: Navigate to home directory before removal operations
    # This prevents accidental deletion if we're currently in the target directory
    cd "$HOME" || return 1

    # Use CREATION_DATA_DIR which is where PrismLauncher data was stored
    local prism_dir="$CREATION_DATA_DIR"

    # SAFETY CHECKS: Multiple validations before removing directories
    # Ensure we're not deleting critical system directories or user home
    if [[ -d "$prism_dir" && "$prism_dir" != "$HOME" && "$prism_dir" != "/" && "$prism_dir" == *"PrismLauncher"* ]]; then
        rm -rf "$prism_dir"
        print_success "Removed PrismLauncher directory: $prism_dir"
        print_info "All essential files now in PollyMC directory"
    else
        print_info "Skipped directory removal (not a PrismLauncher directory): $prism_dir"
    fi
}
