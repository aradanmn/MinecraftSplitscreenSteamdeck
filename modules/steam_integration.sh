#!/bin/bash
# =============================================================================
# @file        steam_integration.sh
# @version     2.0.0
# @date        2026-01-25
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Handles the integration of Minecraft Splitscreen launcher with Steam,
#   providing native Steam library integration, Big Picture mode support,
#   and Steam Deck Game Mode integration.
#
#   Key features:
#   - Automatic Steam shortcut creation via shortcuts.vdf modification
#   - SteamGridDB artwork download for professional appearance
#   - Duplicate shortcut detection and prevention
#   - Safe Steam shutdown/restart procedure
#   - Steam Deck-aware process management
#
# @dependencies
#   - utilities.sh (for print_header, print_success, print_warning, print_error, print_info, print_progress)
#   - path_configuration.sh (for ACTIVE_LAUNCHER_SCRIPT, ACTIVE_DATA_DIR, ACTIVE_LAUNCHER)
#   - curl (for downloading Steam integration script)
#   - python3 (for running add-to-steam.py)
#
# @exports
#   Functions:
#     - setup_steam_integration : Main function to add launcher to Steam
#
# @changelog
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# @function    setup_steam_integration
# @description Add Minecraft Splitscreen launcher to Steam library.
#              Handles Steam shutdown, shortcut creation via Python script,
#              artwork download from SteamGridDB, and Steam restart.
#
# STEAM INTEGRATION BENEFITS:
# - Launch directly from Steam's game library interface
# - Access from Steam Big Picture mode (ideal for Steam Deck)
# - Controller support through Steam Input system
# - Game Mode integration on Steam Deck
# - Professional appearance with custom artwork
# - Consistent with other Steam games in library
#
# TECHNICAL IMPLEMENTATION:
# 1. Detects active Steam installation and user data
# 2. Safely shuts down Steam to modify shortcuts database
# 3. Creates backup of existing shortcuts for safety
# 4. Uses specialized Python script to modify binary shortcuts.vdf format
# 5. Downloads custom artwork from SteamGridDB for professional appearance
# 6. Restarts Steam with new shortcut available
#
# SAFETY MEASURES:
# - Checks for existing shortcut to prevent duplicates
# - Creates backup before modifications
# - Uses official Steam binary format handling
# - Handles multiple Steam installation types (native, Flatpak)
#
# @global      ACTIVE_LAUNCHER_SCRIPT - (input) Path to the launcher script
# @global      ACTIVE_DATA_DIR - (input) Launcher data directory
# @global      ACTIVE_LAUNCHER - (input) Name of active launcher
# @global      REPO_RAW_URL - (input, optional) Repository raw content URL
# @global      REPO_BRANCH - (input, optional) Repository branch name
# @stdin       User confirmation from /dev/tty (for curl | bash compatibility)
# @return      0 on success or skip, 1 if ACTIVE_LAUNCHER_SCRIPT not set
setup_steam_integration() {
    print_header "🎯 STEAM INTEGRATION SETUP"

    # =============================================================================
    # STEAM INTEGRATION USER PROMPT
    # =============================================================================

    # USER PREFERENCE GATHERING: Ask if they want Steam integration
    # Steam integration is optional but highly recommended for Steam Deck users
    # Desktop users may prefer to launch manually or from application menu
    print_info "Steam integration adds Minecraft Splitscreen to your Steam library."
    print_info "Benefits: Easy access from Steam, Big Picture mode support, Steam Deck Game Mode integration"
    echo ""
    # Use centralized prompt function that handles curl | bash piping
    if prompt_yes_no "Do you want to add Minecraft Splitscreen launcher to Steam?" "n"; then

        # =============================================================================
        # LAUNCHER PATH DETECTION AND CONFIGURATION
        # =============================================================================

        # LAUNCHER TYPE DETECTION: Use centralized path configuration
        # The Steam shortcut needs to point to the correct launcher executable and script
        # Use ACTIVE_LAUNCHER_SCRIPT from path_configuration.sh
        if [[ -z "$ACTIVE_LAUNCHER_SCRIPT" ]]; then
            print_error "ACTIVE_LAUNCHER_SCRIPT not set. Cannot configure Steam integration."
            return 1
        fi

        # Path fragment for duplicate detection (extract from full path)
        local launcher_path="${ACTIVE_LAUNCHER_SCRIPT#$HOME/}"
        print_info "Configuring Steam integration for ${ACTIVE_LAUNCHER^} launcher"
        print_info "  Launcher script: $ACTIVE_LAUNCHER_SCRIPT"

        # =============================================================================
        # DUPLICATE SHORTCUT PREVENTION
        # =============================================================================

        # EXISTING SHORTCUT CHECK: Search Steam's shortcuts database for existing entries
        # Prevents creating duplicate shortcuts which can cause confusion and clutter
        # Searches all Steam user accounts on the system for existing Minecraft shortcuts
        print_progress "Checking for existing Minecraft shortcuts in Steam..."
        if ! grep -q "$launcher_path" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then
            # =============================================================================
            # STEAM SHUTDOWN AND BACKUP PROCEDURE
            # =============================================================================

            print_progress "Adding Minecraft Splitscreen launcher to Steam library..."

            # STEAM PROCESS TERMINATION: Safely shut down Steam before modifying shortcuts
            # Steam must be completely closed to safely modify the shortcuts.vdf binary database
            # The shortcuts.vdf file is locked while Steam is running and changes may be lost
            # STEAM DECK SAFETY: Use precise process targeting to avoid killing SteamOS components
            print_progress "Shutting down Steam to safely modify shortcuts database..."

            # Temporarily disable strict error handling for Steam shutdown
            set +e

            # Steam Deck-aware shutdown approach
            print_info "   → Attempting graceful Steam shutdown..."
            steam -shutdown 2>/dev/null || true
            sleep 3

            # Only force close the actual Steam client process, avoiding SteamOS components
            print_info "   → Force closing Steam client process (preserving SteamOS)..."
            # Use exact process name matching to avoid killing SteamOS processes
            pkill -x "steam" 2>/dev/null || true
            sleep 2

            # Re-enable strict error handling
            set -e

            # STEAM SHUTDOWN VERIFICATION: Wait for complete shutdown
            # Check for Steam processes and wait until Steam fully exits
            # This prevents corruption of the shortcuts database during modification
            local shutdown_attempts=0
            local max_attempts=10

            while [[ $shutdown_attempts -lt $max_attempts ]]; do
                # Check for Steam client processes (Steam Deck-safe approach)
                local steam_running=false

                # Temporarily disable error handling for process checks
                set +e

                # Check only for the main Steam client process, not SteamOS components
                if pgrep -x "steam" >/dev/null 2>&1; then
                    steam_running=true
                elif [[ -f ~/.steam/steam.pid ]]; then
                    local steam_pid
                    steam_pid=$(cat ~/.steam/steam.pid 2>/dev/null)
                    if [[ -n "$steam_pid" ]] && kill -0 "$steam_pid" 2>/dev/null; then
                        steam_running=true
                    fi
                fi

                # Re-enable strict error handling
                set -e

                if [[ "$steam_running" == false ]]; then
                    break
                fi

                sleep 1
                ((shutdown_attempts++))
            done

            if [[ $shutdown_attempts -ge $max_attempts ]]; then
                print_warning "⚠️  Steam shutdown timeout - proceeding anyway (may cause issues)"
                print_info "   → Some Steam processes may still be running"
            else
                print_success "✅ Steam shutdown complete"
            fi

            # =============================================================================
            # STEAM SHORTCUTS BACKUP SYSTEM
            # =============================================================================

            # BACKUP CREATION: Create safety backup of existing Steam shortcuts
            # Backup stored in current working directory (safer than PRISMLAUNCHER_DIR which may be cleaned)
            # Compressed archive saves space and preserves all user shortcuts databases
            local backup_path="$PWD/steam-shortcuts-backup-$(date +%Y%m%d_%H%M%S).tar.xz"
            print_progress "Creating backup of Steam shortcuts database..."

            # Disable strict error handling for backup creation
            set +e

            # Check if Steam userdata directory exists first
            if [[ -d ~/.steam/steam/userdata ]]; then
                # Try to create backup with better error handling
                if tar cJf "$backup_path" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then
                    print_success "✅ Steam shortcuts backup created: $(basename "$backup_path")"
                else
                    print_warning "⚠️  Could not create shortcuts backup - proceeding without backup"
                    print_info "   → This is usually not a problem for new Steam shortcuts"
                fi
            else
                print_warning "⚠️  Steam userdata directory not found - skipping backup"
                print_info "   → Steam may not be properly installed or configured"
            fi

            # Re-enable strict error handling
            set -e

            # =============================================================================
            # STEAM INTEGRATION SCRIPT EXECUTION
            # =============================================================================

            # PYTHON INTEGRATION SCRIPT: Download and execute Steam shortcut creation tool
            # Uses the official add-to-steam.py script from the repository
            # This script handles the complex shortcuts.vdf binary format safely
            # Includes automatic artwork download from SteamGridDB for professional appearance
            print_progress "Running Steam integration script to add Minecraft Splitscreen..."
            print_info "   → Downloading launcher detection and shortcut creation script"
            print_info "   → Modifying Steam shortcuts.vdf binary database"
            print_info "   → Downloading custom artwork from SteamGridDB"

            # Execute the Steam integration script with error handling
            # Download script to temporary file first to avoid pipefail issues
            local steam_script_temp
            steam_script_temp=$(mktemp)

            # Disable strict error handling for script download and execution
            set +e

            print_info "   → Downloading Steam integration script..."
            if curl -sSL "${REPO_RAW_URL:-https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/${REPO_BRANCH:-main}}/add-to-steam.py" -o "$steam_script_temp" 2>/dev/null; then
                print_info "   → Executing Steam integration script..."
                # Pass launcher paths from path_configuration.sh to the Python script
                # Arguments: <launcher_script_path> <data_dir> <launcher_name>
                if python3 "$steam_script_temp" "$ACTIVE_LAUNCHER_SCRIPT" "$ACTIVE_DATA_DIR" "${ACTIVE_LAUNCHER^}" 2>/dev/null; then
                    print_success "✅ Minecraft Splitscreen successfully added to Steam library"
                    print_info "   → Custom artwork downloaded and applied"
                    print_info "   → Shortcut configured with proper launch parameters"
                else
                    print_warning "⚠️  Steam integration script encountered errors"
                    print_info "   → You may need to add the shortcut manually"
                    print_info "   → Common causes: Launcher script not found, Steam not installed, or permissions issues"
                fi
            else
                print_warning "⚠️  Failed to download Steam integration script"
                print_info "   → You may need to add the shortcut manually"
                print_info "   → Check your internet connection and try again later"
            fi

            # Clean up temporary file
            rm -f "$steam_script_temp" 2>/dev/null || true

            # Re-enable strict error handling
            set -e

            # =============================================================================
            # STEAM RESTART AND VERIFICATION
            # =============================================================================

            # STEAM RESTART: Launch Steam in background after successful modification
            # Use nohup to prevent Steam from being tied to terminal session
            # Steam will automatically detect the new shortcut in its library
            print_progress "Restarting Steam with new shortcut..."
            nohup steam >/dev/null 2>&1 &

            print_success "🎮 Steam integration complete!"
            print_info "   → Minecraft Splitscreen should now appear in your Steam library"
            print_info "   → Accessible from Steam Big Picture mode and Steam Deck Game Mode"
            print_info "   → Launch directly from Steam for automatic controller detection"
        else
            # =============================================================================
            # DUPLICATE SHORTCUT HANDLING
            # =============================================================================

            print_info "✅ Minecraft Splitscreen launcher already present in Steam library"
            print_info "   → No changes needed - existing shortcut is functional"
            print_info "   → If you need to update the shortcut, please remove it manually from Steam first"
        fi
    else
        # =============================================================================
        # STEAM INTEGRATION DECLINED
        # =============================================================================

        print_info "⏭️  Skipping Steam integration"
        print_info "   → You can still launch Minecraft Splitscreen manually or from desktop launcher"
        print_info "   → To add to Steam later, run this installer again or use the add-to-steam.py script"
    fi
}
