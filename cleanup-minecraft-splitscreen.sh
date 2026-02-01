#!/bin/bash
# =============================================================================
# MINECRAFT SPLITSCREEN CLEANUP SCRIPT
# =============================================================================
# @file        cleanup-minecraft-splitscreen.sh
# @version     1.0.0
# @date        2026-02-01
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Removes all components installed by the Minecraft Splitscreen installer.
#   Works on Steam Deck (SteamOS) and Bazzite (Fedora Atomic).
#
# @usage
#   ./cleanup-minecraft-splitscreen.sh [OPTIONS]
#
# @options
#   --dry-run      Show what would be removed without deleting
#   --force        Skip confirmation prompts
#   --keep-java    Preserve Java installations (default)
#   --remove-java  Also remove Java installations
#   --help         Show this help message
# =============================================================================

set -euo pipefail

# Configuration
readonly SCRIPT_VERSION="1.0.0"
DRY_RUN=false
FORCE=false
KEEP_JAVA=true  # Default to keeping Java (it's useful for other things)

# Flatpak IDs
readonly PRISM_FLATPAK_ID="org.prismlauncher.PrismLauncher"
readonly POLLYMC_FLATPAK_ID="org.fn2006.PollyMC"

# Data directories to clean
PATHS_TO_CLEAN=(
    # PollyMC data directories
    "$HOME/.local/share/PollyMC"
    "$HOME/.var/app/org.fn2006.PollyMC"

    # PrismLauncher data directories
    "$HOME/.local/share/PrismLauncher"
    "$HOME/.var/app/org.prismlauncher.PrismLauncher"

    # Logs
    "$HOME/.local/share/MinecraftSplitscreen"

    # Desktop files
    "$HOME/Desktop/MinecraftSplitscreen.desktop"
    "$HOME/.local/share/applications/MinecraftSplitscreen.desktop"
)

# Java directory (optionally preserved)
readonly JAVA_DIR="$HOME/.local/jdk"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Color output functions
print_header() { echo -e "\n\033[1;34m=== $1 ===\033[0m"; }
print_success() { echo -e "\033[0;32m[OK]\033[0m $1"; }
print_warning() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
print_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
print_info() { echo -e "\033[0;36m[INFO]\033[0m $1"; }
print_dry() { echo -e "\033[0;35m[DRY-RUN]\033[0m Would: $1"; }

# Safe remove function
safe_remove() {
    local path="$1"
    local description="${2:-$path}"

    if [[ ! -e "$path" ]]; then
        print_info "Already removed: $description"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if [[ -d "$path" ]]; then
            local size
            size=$(du -sh "$path" 2>/dev/null | cut -f1) || size="unknown"
            print_dry "Remove directory: $description ($size)"
        else
            print_dry "Remove file: $description"
        fi
        return 0
    fi

    if rm -rf "$path" 2>/dev/null; then
        print_success "Removed: $description"
    else
        print_error "Failed to remove: $description"
        return 1
    fi
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

cleanup_steam_integration() {
    print_header "STEAM INTEGRATION"

    local steam_userdata="$HOME/.steam/steam/userdata"

    if [[ ! -d "$steam_userdata" ]]; then
        print_info "Steam userdata not found - skipping"
        return 0
    fi

    # Find Steam shortcut entries
    local found_shortcuts=false
    for shortcuts_file in "$steam_userdata"/*/config/shortcuts.vdf; do
        if [[ -f "$shortcuts_file" ]]; then
            if grep -q "Minecraft Splitscreen\|minecraftSplitscreen" "$shortcuts_file" 2>/dev/null; then
                found_shortcuts=true
                print_warning "Found Minecraft entry in: $shortcuts_file"
            fi
        fi
    done

    if [[ "$found_shortcuts" == true ]]; then
        print_info "Steam shortcuts.vdf is binary - manual removal required:"
        print_info "  1. Open Steam"
        print_info "  2. Go to Library"
        print_info "  3. Right-click 'Minecraft Splitscreen'"
        print_info "  4. Select 'Manage' > 'Remove non-Steam game'"
    else
        print_info "No Minecraft Splitscreen found in Steam shortcuts"
    fi

    # Check for grid artwork
    for grid_dir in "$steam_userdata"/*/config/grid; do
        if [[ -d "$grid_dir" ]]; then
            local artwork_count
            artwork_count=$(find "$grid_dir" -type f 2>/dev/null | wc -l) || artwork_count=0
            if [[ "$artwork_count" -gt 0 ]]; then
                print_info "Grid artwork directory has $artwork_count files: $grid_dir"
                print_info "  (Minecraft Splitscreen artwork may be among them)"
            fi
        fi
    done
}

cleanup_flatpaks() {
    print_header "FLATPAK INSTALLATIONS"

    if ! command -v flatpak &>/dev/null; then
        print_info "Flatpak not installed - skipping"
        return 0
    fi

    # Check and remove PollyMC Flatpak
    if flatpak list --app 2>/dev/null | grep -q "$POLLYMC_FLATPAK_ID"; then
        if [[ "$DRY_RUN" == true ]]; then
            print_dry "Uninstall Flatpak: PollyMC ($POLLYMC_FLATPAK_ID)"
        else
            print_info "Uninstalling PollyMC Flatpak..."
            if flatpak uninstall -y --noninteractive "$POLLYMC_FLATPAK_ID" 2>/dev/null; then
                print_success "Removed PollyMC Flatpak"
            else
                print_warning "Failed to remove PollyMC Flatpak (may need: flatpak uninstall $POLLYMC_FLATPAK_ID)"
            fi
        fi
    else
        print_info "PollyMC Flatpak not installed"
    fi

    # Check and remove PrismLauncher Flatpak
    if flatpak list --app 2>/dev/null | grep -q "$PRISM_FLATPAK_ID"; then
        if [[ "$DRY_RUN" == true ]]; then
            print_dry "Uninstall Flatpak: PrismLauncher ($PRISM_FLATPAK_ID)"
        else
            print_info "Uninstalling PrismLauncher Flatpak..."
            if flatpak uninstall -y --noninteractive "$PRISM_FLATPAK_ID" 2>/dev/null; then
                print_success "Removed PrismLauncher Flatpak"
            else
                print_warning "Failed to remove PrismLauncher Flatpak (may need: flatpak uninstall $PRISM_FLATPAK_ID)"
            fi
        fi
    else
        print_info "PrismLauncher Flatpak not installed"
    fi
}

cleanup_data_directories() {
    print_header "DATA DIRECTORIES"

    for path in "${PATHS_TO_CLEAN[@]}"; do
        safe_remove "$path" "$(basename "$path")"
    done

    # Clean up icon directories (may be in various locations)
    for icon_dir in "$HOME/minecraft-splitscreen-icons" "./minecraft-splitscreen-icons"; do
        if [[ -d "$icon_dir" ]]; then
            safe_remove "$icon_dir" "Icon directory: $icon_dir"
        fi
    done

    # Clean up any temp installer directories
    for tmp_dir in /tmp/minecraft-splitscreen-* "$HOME/.cache/minecraft-splitscreen"*; do
        if [[ -e "$tmp_dir" ]]; then
            safe_remove "$tmp_dir" "Temp directory: $(basename "$tmp_dir")"
        fi
    done
}

cleanup_java() {
    print_header "JAVA INSTALLATION"

    if [[ "$KEEP_JAVA" == true ]]; then
        print_info "Keeping Java installation (--keep-java is default)"
        if [[ -d "$JAVA_DIR" ]]; then
            print_info "  Location: $JAVA_DIR"
            local java_versions
            java_versions=$(ls -1 "$JAVA_DIR" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
            if [[ -n "$java_versions" ]]; then
                print_info "  Versions: $java_versions"
            fi
        else
            print_info "  (No Java installation found at $JAVA_DIR)"
        fi
        return 0
    fi

    if [[ -d "$JAVA_DIR" ]]; then
        safe_remove "$JAVA_DIR" "Java installations"

        # Also clean up profile entries
        if [[ -f "$HOME/.profile" ]]; then
            if grep -q "JAVA_.*_HOME\|\.local/jdk" "$HOME/.profile" 2>/dev/null; then
                if [[ "$DRY_RUN" == true ]]; then
                    print_dry "Remove JAVA_*_HOME entries from ~/.profile"
                else
                    # Create backup
                    local backup="$HOME/.profile.backup-$(date +%Y%m%d%H%M%S)"
                    cp "$HOME/.profile" "$backup"
                    print_info "Backed up ~/.profile to $backup"

                    # Remove Java-related lines
                    sed -i '/JAVA_.*_HOME/d' "$HOME/.profile" 2>/dev/null || true
                    sed -i '/\.local\/jdk/d' "$HOME/.profile" 2>/dev/null || true
                    print_success "Cleaned Java entries from ~/.profile"
                fi
            fi
        fi
    else
        print_info "No Java installation found at $JAVA_DIR"
    fi
}

# =============================================================================
# SUMMARY AND CONFIRMATION
# =============================================================================

show_summary() {
    print_header "MINECRAFT SPLITSCREEN CLEANUP v${SCRIPT_VERSION}"

    echo ""
    echo "This script will remove:"
    echo "  - PollyMC data and AppImage (~/.local/share/PollyMC)"
    echo "  - PollyMC Flatpak data (~/.var/app/org.fn2006.PollyMC)"
    echo "  - PrismLauncher data and AppImage (~/.local/share/PrismLauncher)"
    echo "  - PrismLauncher Flatpak data (~/.var/app/org.prismlauncher.PrismLauncher)"
    echo "  - Minecraft instances (latestUpdate-1 through latestUpdate-4)"
    echo "  - Desktop shortcuts and application menu entries"
    echo "  - Installer logs (~/.local/share/MinecraftSplitscreen)"
    echo "  - PollyMC and PrismLauncher Flatpak applications"
    echo ""

    if [[ "$KEEP_JAVA" == true ]]; then
        echo -e "\033[0;32m  [PRESERVED]\033[0m Java installations at ~/.local/jdk/"
    else
        echo -e "\033[0;33m  [REMOVED]\033[0m Java installations at ~/.local/jdk/"
    fi
    echo ""

    echo "Note: Steam integration (shortcuts) requires manual removal:"
    echo "  Steam > Library > Right-click 'Minecraft Splitscreen' > Remove"
    echo ""
}

show_detected_components() {
    print_header "DETECTED COMPONENTS"

    local found_any=false

    # Check PollyMC
    if [[ -d "$HOME/.local/share/PollyMC" ]]; then
        local size
        size=$(du -sh "$HOME/.local/share/PollyMC" 2>/dev/null | cut -f1) || size="?"
        print_info "PollyMC AppImage data: $size"
        found_any=true
    fi
    if [[ -d "$HOME/.var/app/org.fn2006.PollyMC" ]]; then
        local size
        size=$(du -sh "$HOME/.var/app/org.fn2006.PollyMC" 2>/dev/null | cut -f1) || size="?"
        print_info "PollyMC Flatpak data: $size"
        found_any=true
    fi

    # Check PrismLauncher
    if [[ -d "$HOME/.local/share/PrismLauncher" ]]; then
        local size
        size=$(du -sh "$HOME/.local/share/PrismLauncher" 2>/dev/null | cut -f1) || size="?"
        print_info "PrismLauncher AppImage data: $size"
        found_any=true
    fi
    if [[ -d "$HOME/.var/app/org.prismlauncher.PrismLauncher" ]]; then
        local size
        size=$(du -sh "$HOME/.var/app/org.prismlauncher.PrismLauncher" 2>/dev/null | cut -f1) || size="?"
        print_info "PrismLauncher Flatpak data: $size"
        found_any=true
    fi

    # Check Flatpaks
    if command -v flatpak &>/dev/null; then
        if flatpak list --app 2>/dev/null | grep -q "$POLLYMC_FLATPAK_ID"; then
            print_info "PollyMC Flatpak app installed"
            found_any=true
        fi
        if flatpak list --app 2>/dev/null | grep -q "$PRISM_FLATPAK_ID"; then
            print_info "PrismLauncher Flatpak app installed"
            found_any=true
        fi
    fi

    # Check logs
    if [[ -d "$HOME/.local/share/MinecraftSplitscreen" ]]; then
        local log_count
        log_count=$(find "$HOME/.local/share/MinecraftSplitscreen" -type f 2>/dev/null | wc -l) || log_count=0
        print_info "Log files: $log_count"
        found_any=true
    fi

    # Check desktop shortcuts
    if [[ -f "$HOME/Desktop/MinecraftSplitscreen.desktop" ]]; then
        print_info "Desktop shortcut found"
        found_any=true
    fi
    if [[ -f "$HOME/.local/share/applications/MinecraftSplitscreen.desktop" ]]; then
        print_info "App menu entry found"
        found_any=true
    fi

    # Check Java
    if [[ -d "$JAVA_DIR" ]]; then
        local size
        size=$(du -sh "$JAVA_DIR" 2>/dev/null | cut -f1) || size="?"
        print_info "Java installations: $size (will be preserved)"
        found_any=true
    fi

    if [[ "$found_any" == false ]]; then
        print_info "No Minecraft Splitscreen components detected"
        print_info "System appears to be clean already"
    fi

    echo ""
}

confirm_cleanup() {
    if [[ "$FORCE" == true ]]; then
        print_info "Skipping confirmation (--force)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY-RUN mode - no changes will be made"
        return 0
    fi

    # Use /dev/tty for input (works with curl | bash)
    echo -n "Are you sure you want to proceed? [y/N]: "
    local response
    if read -r response < /dev/tty 2>/dev/null; then
        if [[ ! "${response,,}" =~ ^y(es)?$ ]]; then
            print_info "Cleanup cancelled by user"
            exit 0
        fi
    else
        print_error "Cannot read user input - use --force to skip confirmation"
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

show_help() {
    cat << 'EOF'
Minecraft Splitscreen Cleanup Script

Removes all components installed by the Minecraft Splitscreen installer.
Works on Steam Deck (SteamOS) and Bazzite (Fedora Atomic).

USAGE:
    ./cleanup-minecraft-splitscreen.sh [OPTIONS]

OPTIONS:
    --dry-run      Show what would be removed without actually deleting
    --force        Skip confirmation prompts (useful for scripting)
    --keep-java    Preserve Java installations at ~/.local/jdk/ (default)
    --remove-java  Also remove Java installations
    --help, -h     Show this help message

EXAMPLES:
    # See what would be cleaned up
    ./cleanup-minecraft-splitscreen.sh --dry-run

    # Clean everything except Java
    ./cleanup-minecraft-splitscreen.sh

    # Clean everything including Java, no prompts
    ./cleanup-minecraft-splitscreen.sh --remove-java --force

    # Remote cleanup via SSH
    ssh deck@steamdeck './cleanup-minecraft-splitscreen.sh --force'

NOTE:
    Steam integration (non-Steam game shortcuts) must be removed manually:
    Steam > Library > Right-click 'Minecraft Splitscreen' > Manage > Remove

EOF
}

main() {
    show_summary
    show_detected_components
    confirm_cleanup

    cleanup_steam_integration
    cleanup_flatpaks
    cleanup_data_directories
    cleanup_java

    print_header "CLEANUP COMPLETE"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        print_info "This was a dry run. No files were modified."
        print_info "Run without --dry-run to perform actual cleanup."
    else
        echo ""
        print_success "Minecraft Splitscreen has been removed from your system."
        print_info "You may need to restart Steam to see changes in your library."
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --keep-java)
            KEEP_JAVA=true
            shift
            ;;
        --remove-java)
            KEEP_JAVA=false
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main
