#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - Steam Integration Module
# =============================================================================
# 
# This module handles the integration of Minecraft Splitscreen launcher with
# Steam, providing native Steam library integration, Big Picture mode support,
# and Steam Deck Game Mode integration.
#
# Functions provided:
# - setup_steam_integration: Add Minecraft Splitscreen launcher to Steam library
#
# =============================================================================

# setup_steam_integration: Add Minecraft Splitscreen launcher to Steam library
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
# 6. Leaves Steam stopped — it picks up the new shortcut on its next normal
#    start (auto-restarting inherited the installer's environment and died
#    headless / over SSH, killing the user's Steam session — see issue #56)
#
# SAFETY MEASURES:
# - Checks for existing shortcut to prevent duplicates
# - Creates backup before modifications
# - Uses official Steam binary format handling
# - Handles multiple Steam installation types (native, Flatpak)
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
    read -p "Do you want to add Minecraft Splitscreen launcher to Steam? [y/N]: " add_to_steam
    if [[ "$add_to_steam" =~ ^[Yy]$ ]]; then
        
        # =============================================================================
        # LAUNCHER PATH DETECTION AND CONFIGURATION
        # =============================================================================
        
        # Use PolyMC path signature for duplicate detection.
        local launcher_path="local/share/PolyMC/minecraft"
        print_info "Configuring Steam integration for PolyMC"
        
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
            # Only touch Steam at all if it is actually running (headless/SSH
            # installs usually have no Steam client up — nothing to shut down)
            local steam_was_running=false

            # Temporarily disable strict error handling for Steam shutdown
            set +e

            if pgrep -x "steam" >/dev/null 2>&1; then
                steam_was_running=true
                print_progress "Shutting down Steam to safely modify shortcuts database..."

                # Steam Deck-aware shutdown approach
                print_info "   → Attempting graceful Steam shutdown..."
                steam -shutdown 2>/dev/null || true
                sleep 3

                # Only force close the actual Steam client process, avoiding SteamOS components
                print_info "   → Force closing Steam client process (preserving SteamOS)..."
                # Use exact process name matching to avoid killing SteamOS processes
                pkill -x "steam" 2>/dev/null || true
                sleep 2
            else
                print_info "   → Steam is not running - shortcuts database is safe to edit"
            fi

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
                shutdown_attempts=$((shutdown_attempts + 1))
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
            # Backup stored in current working directory (safer than TARGET_DIR which may be cleaned)
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
            
            # PYTHON INTEGRATION SCRIPT: Execute Steam shortcut creation tool.
            # Prefer local repository copy for version consistency; fall back to download.
            # This script handles the complex shortcuts.vdf binary format safely
            # Includes automatic artwork download from SteamGridDB for professional appearance
            print_progress "Running Steam integration script to add Minecraft Splitscreen..."
            print_info "   → Preparing launcher detection and shortcut creation script"
            print_info "   → Modifying Steam shortcuts.vdf binary database"
            print_info "   → Downloading custom artwork from SteamGridDB"
            
            # Execute the Steam integration script with error handling
            # Download script to temporary file first to avoid pipefail issues
            local steam_script_temp
            steam_script_temp=$(mktemp)
            
            # Disable strict error handling for script download and execution
            set +e
            
            if [[ -f "${SCRIPT_DIR:-}/add-to-steam.py" ]]; then
                print_info "   → Using local add-to-steam.py from repository checkout"
                cp "${SCRIPT_DIR}/add-to-steam.py" "$steam_script_temp"
            else
                print_info "   → Downloading Steam integration script..."
            fi

            # Fix #51 (D14): fetch_url replaces the bare curl call.
            if [[ -s "$steam_script_temp" ]] || \
               fetch_url "${MCSS_REPO_RAW_URL}/add-to-steam.py" \
                   "$steam_script_temp" 2>/dev/null; then
                print_info "   → Executing Steam integration script..."
                # Execute the downloaded script with proper error handling.
                # #45/D16 residual (#51 sweep): the script's explicit-root
                # override existed but no caller passed it — a relocated
                # TARGET_DIR install always fell through to the script's
                # hardcoded $HOME probes. Hand it the real root.
                if MCSS_TARGET_DIR="$TARGET_DIR" \
                    python3 "$steam_script_temp" 2>/dev/null; then
                    print_success "✅ Minecraft Splitscreen successfully added to Steam library"
                    print_info "   → Custom artwork downloaded and applied"
                    print_info "   → Shortcut configured with proper launch parameters"
                else
                    print_warning "⚠️  Steam integration script encountered errors"
                    print_info "   → You may need to add the shortcut manually"
                    print_info "   → Common causes: PolyMC not found, Steam not installed, or permissions issues"
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
            # STEAM PICKS UP THE SHORTCUT ON ITS NEXT START
            # =============================================================================

            # NO AUTO-RESTART (issue #56): relaunching Steam here inherits the
            # installer's environment — over SSH / headless there is no
            # DISPLAY/Wayland socket, so the new Steam process dies ("Unable to
            # open display") and the user's Steam session stays down. Steam
            # reads shortcuts.vdf on every normal start, so simply leaving it
            # stopped is safe; the user restarts it however they normally would.
            print_success "🎮 Steam integration complete!"
            print_info "   → Minecraft Splitscreen will appear in your Steam library the next time Steam starts"
            if [[ "$steam_was_running" == true ]]; then
                print_info "   → Steam was shut down to edit the shortcuts database - start Steam (or Return to Gaming Mode on Steam Deck) to see the shortcut"
            else
                print_info "   → Start Steam (or Return to Gaming Mode on Steam Deck) to see the shortcut"
            fi
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
