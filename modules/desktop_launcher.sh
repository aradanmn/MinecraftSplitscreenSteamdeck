#!/bin/bash
# =============================================================================
# @file        desktop_launcher.sh
# @version     3.0.0
# @date        2026-01-25
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Creates native desktop launchers and application menu integration for the
#   Minecraft Splitscreen launcher. Provides seamless integration with Linux
#   desktop environments following freedesktop.org Desktop Entry Specification.
#
#   Key features:
#   - .desktop file generation for all Linux desktop environments
#   - Application menu integration via ~/.local/share/applications/
#   - Desktop shortcut creation
#   - SteamGridDB icon download with fallback hierarchy
#   - Desktop database update for immediate availability
#
# @dependencies
#   - utilities.sh (for print_header, print_success, print_warning, print_error, print_info, print_progress)
#   - wget (for icon download)
#   - path_configuration.sh (for ACTIVE_LAUNCHER_SCRIPT, ACTIVE_INSTANCES_DIR, ACTIVE_LAUNCHER)
#
# @exports
#   Functions:
#     - create_desktop_launcher : Main function to create desktop integration
#
# @changelog
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# @function    create_desktop_launcher
# @description Generate .desktop file for system integration with Linux desktops.
#              Creates both a desktop shortcut and application menu entry.
#              Downloads custom icon from SteamGridDB with intelligent fallbacks.
#
# DESKTOP LAUNCHER BENEFITS:
# - Native desktop environment integration (GNOME, KDE, XFCE, etc.)
# - Appears in application menus and search results
# - Desktop shortcut for quick access
# - Proper icon and metadata for professional appearance
# - Follows freedesktop.org Desktop Entry Specification
# - Works with all Linux desktop environments
#
# ICON HIERARCHY:
# 1. SteamGridDB custom icon (downloaded, professional appearance)
# 2. PollyMC instance icon (if PollyMC setup successful)
# 3. PrismLauncher instance icon (fallback)
# 4. System generic icon (ultimate fallback)
#
# DESKTOP FILE LOCATIONS:
# - Desktop shortcut: ~/Desktop/MinecraftSplitscreen.desktop
# - System integration: ~/.local/share/applications/MinecraftSplitscreen.desktop
#
# @global      ACTIVE_LAUNCHER_SCRIPT - (input) Path to the launcher script
# @global      ACTIVE_INSTANCES_DIR - (input) Path to instances directory for icon fallback
# @global      ACTIVE_LAUNCHER - (input) Name of active launcher for comments
# @stdin       User confirmation from /dev/tty (for curl | bash compatibility)
# @return      0 on success or skip, 1 if ACTIVE_LAUNCHER_SCRIPT not set
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
    # Use centralized prompt function that handles curl | bash piping
    if prompt_yes_no "Do you want to create a desktop launcher for Minecraft Splitscreen?" "n"; then

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
        local icon_dir="$PWD/minecraft-splitscreen-icons"
        local icon_path="$icon_dir/minecraft-splitscreen-steamgriddb.ico"
        local icon_url="https://cdn2.steamgriddb.com/icon/add7a048049671970976f3e18f21ade3.ico"

        print_progress "Configuring desktop launcher icon..."
        mkdir -p "$icon_dir"  # Ensure icon storage directory exists

        # ICON DOWNLOAD: Fetch SteamGridDB icon if not already present
        # This provides a professional-looking icon that matches Steam integration
        if [[ ! -f "$icon_path" ]]; then
            print_progress "Downloading custom icon from SteamGridDB..."
            if wget -O "$icon_path" "$icon_url" >/dev/null 2>&1; then
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
        local instance_icon_path="$ACTIVE_INSTANCES_DIR/latestUpdate-1/icon.png"

        if [[ -f "$icon_path" ]]; then
            icon_desktop="$icon_path"  # Best: Custom SteamGridDB icon
            print_info "   → Using custom SteamGridDB icon for consistent branding"
        elif [[ -f "$instance_icon_path" ]]; then
            icon_desktop="$instance_icon_path"  # Good: Instance icon from active launcher
            print_info "   → Using instance icon from $ACTIVE_LAUNCHER"
        else
            icon_desktop="application-x-executable"  # Fallback: Generic system executable icon
            print_info "   → Using system default executable icon"
        fi

        # =============================================================================
        # LAUNCHER SCRIPT PATH CONFIGURATION
        # =============================================================================

        # LAUNCHER SCRIPT PATH: Use centralized path configuration
        # The desktop file needs to point to ACTIVE_LAUNCHER_SCRIPT
        if [[ -z "$ACTIVE_LAUNCHER_SCRIPT" ]]; then
            print_error "ACTIVE_LAUNCHER_SCRIPT not set. Cannot create desktop launcher."
            return 1
        fi

        local launcher_script_path="$ACTIVE_LAUNCHER_SCRIPT"
        local launcher_comment="Launch Minecraft splitscreen with ${ACTIVE_LAUNCHER^}"
        print_info "   → Desktop launcher configured for ${ACTIVE_LAUNCHER^}"
        print_info "   → Script path: $launcher_script_path"

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
        print_info "     $ACTIVE_LAUNCHER_SCRIPT"
    fi
}
