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

    # Priority 1: Check for existing Flatpak installation
    # If user already has PollyMC via Flatpak, use that instead of downloading AppImage
    if is_flatpak_installed "${POLLYMC_FLATPAK_ID:-org.fn2006.PollyMC}" 2>/dev/null; then
        print_success "✅ Found existing PollyMC Flatpak installation"
        pollymc_type="flatpak"
        pollymc_data_dir="${POLLYMC_FLATPAK_DATA_DIR:-$HOME/.var/app/org.fn2006.PollyMC/data/PollyMC}"
        USE_POLLYMC=true

        # Ensure Flatpak data directory exists
        mkdir -p "$pollymc_data_dir"
        mkdir -p "$pollymc_data_dir/instances"
        print_info "   → Using Flatpak data directory: $pollymc_data_dir"

    # Priority 2: Check for existing AppImage
    elif [[ -x "${POLLYMC_APPIMAGE_PATH:-$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage}" ]]; then
        print_success "✅ Found existing PollyMC AppImage"
        pollymc_type="appimage"
        pollymc_data_dir="${POLLYMC_APPIMAGE_DIR:-$HOME/.local/share/PollyMC}"
        USE_POLLYMC=true
        print_info "   → Using existing AppImage: ${POLLYMC_APPIMAGE_PATH:-$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage}"

    # Priority 3: Download AppImage (fallback)
    else
        print_progress "No existing PollyMC found - downloading AppImage..."
        pollymc_type="appimage"
        pollymc_data_dir="${POLLYMC_APPIMAGE_DIR:-$HOME/.local/share/PollyMC}"

        # Create PollyMC data directory structure
        mkdir -p "$pollymc_data_dir"

        # Download PollyMC AppImage from official GitHub releases
        local pollymc_url="https://github.com/fn2006/PollyMC/releases/latest/download/PollyMC-Linux-x86_64.AppImage"
        print_progress "Fetching PollyMC from GitHub releases: $(basename "$pollymc_url")..."

        # DOWNLOAD WITH FALLBACK HANDLING
        local appimage_path="${POLLYMC_APPIMAGE_PATH:-$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage}"
        if ! wget -O "$appimage_path" "$pollymc_url"; then
            print_warning "❌ PollyMC download failed - continuing with PrismLauncher as primary launcher"
            print_info "   This is not a critical error - PrismLauncher works fine for splitscreen"
            USE_POLLYMC=false
            return 0
        else
            chmod +x "$appimage_path"
            print_success "✅ PollyMC AppImage downloaded and configured successfully"
            USE_POLLYMC=true
        fi
    fi

    # Store the detected type for later use by launcher script generator
    POLLYMC_INSTALL_TYPE="$pollymc_type"
    POLLYMC_DATA_DIR="$pollymc_data_dir"
    export POLLYMC_INSTALL_TYPE POLLYMC_DATA_DIR

    print_info "   → PollyMC installation type: $pollymc_type"

    # =============================================================================
    # INSTANCE MIGRATION: Transfer all Minecraft instances from PrismLauncher
    # =============================================================================

    # INSTANCE DIRECTORY MIGRATION
    # Copy the complete instances directory structure from PrismLauncher to PollyMC
    # This includes all 4 splitscreen instances with their configurations, mods, and saves
    print_progress "Migrating PrismLauncher instances to PollyMC data directory..."

    # INSTANCES TRANSFER: Copy entire instances folder with all splitscreen configurations
    # Each instance (latestUpdate-1 through latestUpdate-4) contains:
    # - Minecraft version configuration
    # - Fabric mod loader setup
    # - All downloaded mods and their dependencies
    # - Splitscreen-specific mod configurations
    # - Instance-specific settings (memory, Java args, etc.)
    if [[ -d "$PRISMLAUNCHER_DIR/instances" ]]; then
        # Create instances directory if it doesn't exist
        mkdir -p "$pollymc_data_dir/instances"

        # For updates: preserve options.txt and replace instances
        if [[ -d "$pollymc_data_dir/instances" ]]; then
            for i in {1..4}; do
                local instance_name="latestUpdate-$i"
                local instance_path="$pollymc_data_dir/instances/$instance_name"
                local options_file="$instance_path/.minecraft/options.txt"

                if [[ -d "$instance_path" ]]; then
                    print_info "   → Updating $instance_name while preserving settings"

                    # Backup options.txt if it exists
                    if [[ -f "$options_file" ]]; then
                        print_info "     → Preserving existing options.txt for $instance_name"
                        # Create a temporary directory for backups
                        local backup_dir="$pollymc_data_dir/options_backup"
                        mkdir -p "$backup_dir"
                        # Copy with path structure to keep track of which instance it belongs to
                        cp "$options_file" "$backup_dir/${instance_name}_options.txt"
                    fi

                    # Remove old instance but keep options backup
                    rm -rf "$instance_path"
                fi
            done
        fi

        # Copy the updated instances while excluding options.txt files
        rsync -a --exclude='*.minecraft/options.txt' "$PRISMLAUNCHER_DIR/instances/"* "$pollymc_data_dir/instances/"

        # Restore options.txt files from temporary backup location
        local backup_dir="$pollymc_data_dir/options_backup"
        for i in {1..4}; do
            local instance_name="latestUpdate-$i"
            local instance_path="$pollymc_data_dir/instances/$instance_name"
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
        instance_count=$(find "$pollymc_data_dir/instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)
        print_info "   → $instance_count splitscreen instances available in PollyMC"
    else
        print_warning "⚠️  No instances directory found in PrismLauncher - this shouldn't happen"
    fi

    # =============================================================================
    # ACCOUNT CONFIGURATION MIGRATION
    # =============================================================================

    # OFFLINE ACCOUNTS TRANSFER: Copy splitscreen player account configurations
    # The accounts.json file contains offline player profiles for Player 1-4
    # These accounts allow splitscreen gameplay without requiring multiple Microsoft accounts
    if [[ -f "$PRISMLAUNCHER_DIR/accounts.json" ]]; then
        cp "$PRISMLAUNCHER_DIR/accounts.json" "$pollymc_data_dir/"
        print_success "✅ Offline splitscreen accounts copied to PollyMC"
        print_info "   → Player accounts P1, P2, P3, P4 configured for offline gameplay"
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

    cat > "$pollymc_data_dir/pollymc.cfg" <<EOF
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

    if [[ "$pollymc_type" == "flatpak" ]]; then
        # FLATPAK TEST: Verify Flatpak app is accessible
        if flatpak run "${POLLYMC_FLATPAK_ID:-org.fn2006.PollyMC}" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "✅ PollyMC Flatpak compatibility test passed"
        fi
    else
        # APPIMAGE EXECUTION TEST: Run PollyMC with --help flag to verify it works
        local appimage_path="${POLLYMC_APPIMAGE_PATH:-$HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage}"
        if timeout 5s "$appimage_path" --help >/dev/null 2>&1; then
            pollymc_test_passed=true
            print_success "✅ PollyMC AppImage compatibility test passed"
        fi
    fi

    if [[ "$pollymc_test_passed" == true ]]; then
        # =============================================================================
        # POLLYMC INSTANCE VERIFICATION AND FINAL SETUP
        # =============================================================================

        # INSTANCE ACCESS VERIFICATION: Confirm PollyMC can detect and access migrated instances
        print_progress "Verifying PollyMC can access migrated splitscreen instances..."
        local polly_instances_count
        polly_instances_count=$(find "$pollymc_data_dir/instances" -maxdepth 1 -name "latestUpdate-*" -type d 2>/dev/null | wc -l)

        if [[ "$polly_instances_count" -eq 4 ]]; then
            print_success "✅ PollyMC instance verification successful - all 4 instances accessible"
            print_info "   → latestUpdate-1, latestUpdate-2, latestUpdate-3, latestUpdate-4 ready"

            # LAUNCHER SCRIPT CONFIGURATION: Prepare for launcher script generation
            # The actual script generation happens in generate_launcher_script() phase
            setup_pollymc_launcher

            # CLEANUP PHASE: Remove PrismLauncher since PollyMC is working
            # This saves significant disk space (~500MB+) and avoids launcher confusion
            cleanup_prism_launcher

            print_success "🎮 PollyMC is now the primary launcher for splitscreen gameplay"
            print_info "   → PrismLauncher files cleaned up to save disk space"
            print_info "   → Installation type: $pollymc_type"
        else
            print_warning "⚠️  PollyMC instance verification failed - found $polly_instances_count instances instead of 4"
            print_info "   → Falling back to PrismLauncher as primary launcher"
            USE_POLLYMC=false
        fi
    else
        print_warning "❌ PollyMC compatibility test failed"
        print_info "   → This may be due to system restrictions or missing dependencies"
        print_info "   → Falling back to PrismLauncher for gameplay (still fully functional)"
        USE_POLLYMC=false
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

    # SAFETY CHECKS: Multiple validations before removing directories
    # Ensure we're not deleting critical system directories or user home
    if [[ -d "$PRISMLAUNCHER_DIR" && "$PRISMLAUNCHER_DIR" != "$HOME" && "$PRISMLAUNCHER_DIR" != "/" && "$PRISMLAUNCHER_DIR" == *"PrismLauncher"* ]]; then
        rm -rf "$PRISMLAUNCHER_DIR"
        print_success "Removed PrismLauncher directory: $PRISMLAUNCHER_DIR"
        print_info "All essential files now in PollyMC directory"
    else
        print_warning "Skipped directory removal for safety: $PRISMLAUNCHER_DIR"
    fi
}
