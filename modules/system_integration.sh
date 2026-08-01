#!/bin/bash
# =============================================================================
# SYSTEM INTEGRATION MODULE
# =============================================================================
# Makes the splitscreen launcher reachable from the places a user actually
# looks: the Steam library (non-Steam shortcut, so Game Mode / Big Picture can
# launch it with controller input) and the desktop environment (a
# freedesktop.org .desktop entry for menus and search).
#
# #91: merged from steam_integration.sh + desktop_launcher.sh. Both were single
# interactive y/N functions with one caller each, both ran at the same point in
# the install, and both fetched the SAME SteamGridDB icon — which was hardcoded
# in desktop_launcher.sh AND add-to-steam.py. One module, one icon constant.
#
# Public API:
#   setup_steam_integration() — prompts the user, then shuts down Steam
#     (only if running), edits shortcuts.vdf via add-to-steam.py, downloads
#     artwork, and leaves Steam stopped for the user to restart
#   create_desktop_launcher() — prompts the user, then writes the .desktop
#     file to both the desktop and the applications directory
#
# Globals PROVIDED (set here, read elsewhere):
#   MCSS_STEAMGRIDDB_ICON_URL — readonly; the ONE encoding of the icon URL.
#                               Read by create_desktop_launcher and exported
#                               to add-to-steam.py on the env channel
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR           — installer entry; icon storage + launcher path
#   MCSS_INSTANCE_PREFIX — installer entry; PolyMC instance-icon fallback path
#   MCSS_REPO_RAW_URL    — installer entry; add-to-steam.py download base
#   SCRIPT_DIR           — installer entry; local add-to-steam.py copy
#   MCSS_TARGET_DIR      — set here for add-to-steam.py's own root probe (#45/
#                           D16 residual): the script defaults to hardcoded
#                           $HOME probes without it
#
# Inputs:  Steam userdata/shortcuts.vdf, add-to-steam.py (local repo copy or
#          downloaded), SteamGridDB artwork, PolyMC instance icon (fallback).
# Outputs: modifies shortcuts.vdf, downloads artwork, leaves Steam stopped;
#          writes ~/Desktop/MinecraftSplitscreen.desktop and
#          ~/.local/share/applications/MinecraftSplitscreen.desktop.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-07-30  #91: merged steam_integration.sh + desktop_launcher.sh;
#                    SteamGridDB icon URL hoisted to one constant
# =============================================================================

# --- Module-level constants ---
# Guard name kept as _STEAM_INTEGRATION_CONSTANTS_LOCKED (#91): renaming it would
# break re-sourcing for anything that already set it in-process.
# Guarded (house pattern from runtime_context.sh's _MCSS_CONSTANTS_LOCKED):
# modules are re-sourceable within one process, so an unguarded readonly
# would abort on the second source.
if [[ -z "${_STEAM_INTEGRATION_CONSTANTS_LOCKED:-}" ]]; then
    # Fix #86: named literals for the shutdown wait/poll sequence (#86 item e).
    # Grace period after `steam -shutdown` before force-closing the client.
    readonly STEAM_INTEGRATION_GRACEFUL_SHUTDOWN_WAIT_S=3
    # Settle time after `pkill -x steam` before the exit-poll loop starts.
    readonly STEAM_INTEGRATION_FORCE_CLOSE_WAIT_S=2
    # Poll interval while waiting for Steam to fully exit.
    readonly STEAM_INTEGRATION_SHUTDOWN_POLL_INTERVAL_S=1
    # Max poll iterations (~10s at the interval above) before giving up and
    # proceeding anyway.
    readonly STEAM_INTEGRATION_SHUTDOWN_MAX_ATTEMPTS=10
    # #91: the ONE encoding of the SteamGridDB icon URL. It was hardcoded in
    # desktop_launcher.sh:82 AND add-to-steam.py:67 — two files, two languages,
    # no cross-reference. create_desktop_launcher reads it directly;
    # add-to-steam.py receives it on the env channel (same pattern as
    # MCSS_TARGET_DIR, #51/D16).
    readonly MCSS_STEAMGRIDDB_ICON_URL="https://cdn2.steamgriddb.com/icon/add7a048049671970976f3e18f21ade3.ico"
    _STEAM_INTEGRATION_CONSTANTS_LOCKED=1   # process-local — NOT exported
fi

# setup_steam_integration: Add the launcher to Steam as a non-Steam shortcut.
# #56: leaves Steam stopped rather than restarting it — an auto-restart
# inherits the installer's environment, so headless/SSH runs had no
# DISPLAY/Wayland socket and the relaunched Steam died, killing the user's
# session. Steam picks up shortcuts.vdf on its next normal start, so simply
# leaving it stopped (only if it was running) is safe.
# Inputs:
#   Globals: TARGET_DIR, MCSS_REPO_RAW_URL, SCRIPT_DIR (read)
# Outputs:
#   side effects — shortcuts.vdf edited, artwork downloaded, Steam left
#     stopped if it was running; print_* status to stderr
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
    # #185: was a bare read under set -e — a real EOF killed the whole
    # install with no error message, right at this step. --yes now defaults
    # to YES here on purpose (Steam integration is "highly recommended" per
    # the print_info above, and --yes means "do the recommended thing,
    # don't ask"); an ACCIDENTAL bare EOF still defaults to NO, because an
    # unintended EOF must never silently perform an action with real side
    # effects (editing shortcuts.vdf) nobody explicitly asked for.
    local add_to_steam=""
    mcss_prompt "Do you want to add Minecraft Splitscreen launcher to Steam? [y/N]: " \
        "y" "n" add_to_steam
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
                sleep "$STEAM_INTEGRATION_GRACEFUL_SHUTDOWN_WAIT_S"

                # Only force close the actual Steam client process, avoiding SteamOS components
                print_info "   → Force closing Steam client process (preserving SteamOS)..."
                # Use exact process name matching to avoid killing SteamOS processes
                pkill -x "steam" 2>/dev/null || true
                sleep "$STEAM_INTEGRATION_FORCE_CLOSE_WAIT_S"
            else
                print_info "   → Steam is not running - shortcuts database is safe to edit"
            fi

            # Re-enable strict error handling
            set -e
            
            # STEAM SHUTDOWN VERIFICATION: Wait for complete shutdown
            # Check for Steam processes and wait until Steam fully exits
            # This prevents corruption of the shortcuts database during modification
            local shutdown_attempts=0
            local max_attempts="$STEAM_INTEGRATION_SHUTDOWN_MAX_ATTEMPTS"
            
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
                
                sleep "$STEAM_INTEGRATION_SHUTDOWN_POLL_INTERVAL_S"
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
                # #91: MCSS_STEAMGRIDDB_ICON_URL joins MCSS_TARGET_DIR on the
                # same env channel — the icon URL was hardcoded in BOTH this
                # module's desktop half and add-to-steam.py.
                #
                # #184: MUST go through `env`, not a bash prefix-assignment
                # (`VAR=val cmd`). MCSS_STEAMGRIDDB_ICON_URL is `readonly` in
                # THIS shell (line 69) — a prefix assignment still touches the
                # parent shell's own variable-table entry for that name before
                # handing the environment to the child, and bash refuses that
                # for anything already readonly ("readonly variable"), even
                # though the assignment looks child-scoped. `env` spawns a
                # genuinely separate process and never touches our binding at
                # all. This was silently failing behind the `2>/dev/null`
                # below — add-to-steam.py's own hardcoded fallback URL matches
                # this one today, which is the only reason nothing broke.
                if env MCSS_TARGET_DIR="$TARGET_DIR" \
                    MCSS_STEAMGRIDDB_ICON_URL="$MCSS_STEAMGRIDDB_ICON_URL" \
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

# create_desktop_launcher: Write a .desktop entry for system integration.
# ICON HIERARCHY: SteamGridDB custom icon (downloaded) > PolyMC instance icon
# (fallback) > generic system executable icon (ultimate fallback).
# FILE LOCATIONS: desktop shortcut at ~/Desktop/MinecraftSplitscreen.desktop;
# application-menu entry at
# ~/.local/share/applications/MinecraftSplitscreen.desktop.
# Inputs:
#   Globals: TARGET_DIR, MCSS_INSTANCE_PREFIX (read)
# Outputs:
#   side effects — .desktop files written (see FILE LOCATIONS above),
#     icon downloaded, desktop database refreshed if the tool is present
create_desktop_launcher() {
    print_header "🖥️ DESKTOP LAUNCHER SETUP"
    
    # =============================================================================
    # DESKTOP LAUNCHER USER PROMPT
    # =============================================================================
    
    # USER PREFERENCE GATHERING: Ask if they want desktop integration
    # Desktop launchers provide convenient access without terminal or Steam
    # Particularly useful for users who don't use Steam or prefer native desktop integration
    print_info "Desktop launcher creates a native shortcut for your desktop environment."
    print_info "Benefits: Desktop shortcut, application menu entry, search integration"
    echo ""
    # #185: was a bare read under set -e; --yes and a bare EOF both default
    # to NO here (unlike Steam integration above) — a desktop shortcut is a
    # niche convenience, not the installer's main recommended action, and
    # Deck runtime already reports "desktop mode unsupported" regardless.
    local create_desktop=""
    mcss_prompt "Do you want to create a desktop launcher for Minecraft Splitscreen? [y/N]: " \
        "n" "n" create_desktop
    if [[ "$create_desktop" =~ ^[Yy]$ ]]; then
        
        # =============================================================================
        # DESKTOP FILE CONFIGURATION AND PATHS
        # =============================================================================
        
        # DESKTOP FILE SETUP: Define paths and filenames following Linux standards
        # .desktop files follow the freedesktop.org Desktop Entry Specification
        # Standard locations ensure compatibility across all Linux desktop environments
        local desktop_file_name="MinecraftSplitscreen.desktop"
        local desktop_file_path="$HOME/Desktop/$desktop_file_name"  # User desktop shortcut
        local app_dir="$HOME/.local/share/applications"              # System integration directory
        
        # APPLICATIONS DIRECTORY CREATION: Ensure the applications directory exists
        # This directory is where desktop environments look for user-installed applications
        mkdir -p "$app_dir"
        print_info "Desktop file will be created at: $desktop_file_path"
        print_info "Application menu entry will be registered in: $app_dir"
        
        # =============================================================================
        # ICON ACQUISITION AND CONFIGURATION
        # =============================================================================
        
        # CUSTOM ICON DOWNLOAD: Get professional SteamGridDB icon for consistent branding
        # This provides the same visual identity as the Steam integration
        # SteamGridDB provides high-quality gaming artwork used by many Steam applications
        # Stored under TARGET_DIR (#41 home hygiene): the old $PWD dir dropped an icon
        # folder wherever the installer happened to be run from, and the .desktop
        # Icon= then pointed at that transient location.
        local icon_dir="$TARGET_DIR/minecraft-splitscreen-icons"
        local icon_path="$icon_dir/minecraft-splitscreen-steamgriddb.ico"
        # #91: one encoding, shared with add-to-steam.py via the env var below.
        local icon_url="$MCSS_STEAMGRIDDB_ICON_URL"
        
        print_progress "Configuring desktop launcher icon..."
        mkdir -p "$icon_dir"  # Ensure icon storage directory exists
        
        # ICON DOWNLOAD: Fetch SteamGridDB icon if not already present
        # This provides a professional-looking icon that matches Steam integration
        if [[ ! -f "$icon_path" ]]; then
            print_progress "Downloading custom icon from SteamGridDB..."
            # Fix #51 (D14): fetch_url replaces the bare wget call.
            if fetch_url "$icon_url" "$icon_path" >/dev/null 2>&1; then
                print_success "✅ Custom icon downloaded successfully"
            else
                print_warning "⚠️  Custom icon download failed - will use fallback icons"
            fi
        else
            print_info "   → Custom icon already present"
        fi
        
        # =============================================================================
        # ICON SELECTION WITH FALLBACK HIERARCHY
        # =============================================================================
        
        # ICON SELECTION: Determine the best available icon with intelligent fallbacks
        # Priority system ensures we always have a functional icon, preferring custom over generic
        local icon_desktop
        if [[ -f "$icon_path" ]]; then
            icon_desktop="$icon_path"  # Best: Custom SteamGridDB icon
            print_info "   → Using custom SteamGridDB icon for consistent branding"
        elif [[ -f "$TARGET_DIR/instances/${MCSS_INSTANCE_PREFIX}1/icon.png" ]]; then
            icon_desktop="$TARGET_DIR/instances/${MCSS_INSTANCE_PREFIX}1/icon.png"  # Acceptable: PolyMC instance icon
            print_info "   → Using PolyMC instance icon"
        else
            icon_desktop="application-x-executable"  # Fallback: Generic system executable icon
            print_info "   → Using system default executable icon"
        fi
        
        # =============================================================================
        # LAUNCHER SCRIPT PATH CONFIGURATION
        # =============================================================================
        
        # LAUNCHER SCRIPT PATH: Always point to PolyMC splitscreen script.
        local launcher_script_path
        local launcher_comment
        launcher_script_path="$TARGET_DIR/minecraftSplitscreen.sh"
        # #42: splitscreen requires Steam Game Mode (gamescope) — a bare invocation from
        # this Desktop-Mode shortcut is refused by the launcher's runtime_context guard
        # (see #43) rather than crashing (#40) or spawning a runaway. Say so up front.
        launcher_comment="Splitscreen setup only (requires Steam Game Mode to actually play — launch 'Minecraft Splitscreen' from your Steam library)"
        print_info "   → Desktop launcher configured for PolyMC"
        
        # =============================================================================
        # DESKTOP ENTRY FILE GENERATION
        # =============================================================================
        
        # DESKTOP FILE CREATION: Generate .desktop file following freedesktop.org specification
        # This creates a proper desktop entry that integrates with all Linux desktop environments
        # The file contains metadata, execution parameters, and display information
        print_progress "Generating desktop entry file..."
        
        # Desktop Entry Specification fields:
        # - Type=Application: Indicates this is an application launcher
        # - Name: Display name in menus and desktop
        # - Comment: Tooltip/description text
        # - Exec: Command to execute when launched
        # - Icon: Icon file path or theme icon name
        # - Terminal: Whether to run in terminal (false for GUI applications)
        # - Categories: Menu categories for proper organization
        
        cat > "$desktop_file_path" <<EOF
[Desktop Entry]
Type=Application
Name=Minecraft Splitscreen
Comment=$launcher_comment
Exec=$launcher_script_path
Icon=$icon_desktop
Terminal=false
Categories=Game;
EOF
        
        print_success "✅ Desktop entry file created successfully"
        
        # =============================================================================
        # DESKTOP FILE PERMISSIONS AND VALIDATION
        # =============================================================================
        
        # DESKTOP FILE PERMISSIONS: Make the .desktop file executable
        # Many desktop environments require .desktop files to be executable
        # This ensures the launcher appears and functions properly across all DEs
        chmod +x "$desktop_file_path"
        print_info "   → Desktop file permissions set to executable"
        
        # DESKTOP FILE VALIDATION: Basic syntax check
        # Verify the generated .desktop file has required fields
        if [[ -f "$desktop_file_path" ]] && grep -q "Type=Application" "$desktop_file_path"; then
            print_success "✅ Desktop file validation passed"
        else
            print_warning "⚠️  Desktop file validation failed - file may not work properly"
        fi
        
        # =============================================================================
        # SYSTEM INTEGRATION AND REGISTRATION
        # =============================================================================
        
        # SYSTEM INTEGRATION: Copy to applications directory for system-wide access
        # This makes the launcher appear in application menus, search results, and launchers
        # The ~/.local/share/applications directory is the standard location for user applications
        print_progress "Registering application with desktop environment..."
        
        if cp "$desktop_file_path" "$app_dir/$desktop_file_name"; then
            print_success "✅ Application registered in system applications directory"
        else
            print_warning "⚠️  Failed to register application system-wide"
        fi
        
        # =============================================================================
        # DESKTOP DATABASE UPDATE
        # =============================================================================
        
        # DATABASE UPDATE: Refresh desktop database to register new application immediately
        # This ensures the launcher appears in menus without requiring logout/reboot
        # The update-desktop-database command updates the application cache
        print_progress "Updating desktop application database..."
        
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$app_dir" 2>/dev/null || true
            print_success "✅ Desktop database updated - launcher available immediately"
        else
            print_info "   → Desktop database update tool not found (launcher may need logout to appear)"
        fi
        
        # =============================================================================
        # DESKTOP LAUNCHER COMPLETION SUMMARY
        # =============================================================================
        
        print_success "🖥️ Desktop launcher setup complete!"
        print_info ""
        print_info "📋 Desktop Integration Summary:"
        print_info "   → Desktop shortcut: $desktop_file_path"
        print_info "   → Application menu: $app_dir/$desktop_file_name"
        print_info "   → Icon: $(basename "$icon_desktop")"
        print_info "   → Target launcher: $(basename "$launcher_script_path")"
        print_info ""
        print_info "🚀 Access Methods:"
        print_info "   → Double-click desktop shortcut"
        print_info "   → Search for 'Minecraft Splitscreen' in application menu"
        print_info "   → Launch from desktop environment's application launcher"
    else
        # =============================================================================
        # DESKTOP LAUNCHER DECLINED
        # =============================================================================
        
        print_info "⏭️  Skipping desktop launcher creation"
        print_info "   → You can still launch via Steam (if configured) or manually run the script"
        print_info "   → Manual launch command:"
        print_info "     $TARGET_DIR/minecraftSplitscreen.sh"
    fi
}
