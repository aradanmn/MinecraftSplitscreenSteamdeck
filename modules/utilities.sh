#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# @file        utilities.sh
# @version     1.1.0
# @date        2026-01-24
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Core utility functions for the Minecraft Splitscreen installer.
#   Provides consistent output formatting, system detection, and account
#   management functionality used by all other modules.
#
# @dependencies
#   - jq (optional, for JSON merging - falls back to overwrite if missing)
#   - flatpak (optional, for Flatpak preference detection)
#   - ostree (optional, for immutable OS detection)
#
# @exports
#   Functions:
#     - get_prism_executable    : Locate PrismLauncher executable
#     - is_immutable_os         : Detect immutable Linux distributions
#     - should_prefer_flatpak   : Determine preferred package format
#     - print_header            : Display section headers
#     - print_success           : Display success messages
#     - print_warning           : Display warning messages
#     - print_error             : Display error messages
#     - print_info              : Display info messages
#     - print_progress          : Display progress messages
#     - merge_accounts_json     : Merge Minecraft account configurations
#
#   Variables:
#     - IMMUTABLE_OS_NAME       : Set by is_immutable_os() with detected OS name
#
# @changelog
#   1.1.0 (2026-01-24) - Added immutable OS detection and Flatpak preference
#   1.0.0 (2026-01-23) - Initial version with print functions and account merging
# =============================================================================

# =============================================================================
# PRISMLAUNCHER EXECUTABLE DETECTION
# =============================================================================

# -----------------------------------------------------------------------------
# @function    get_prism_executable
# @description Locates the PrismLauncher executable, checking for both the
#              standard AppImage and extracted squashfs-root version (used
#              when FUSE is unavailable).
# @param       None
# @global      PRISMLAUNCHER_DIR - Base directory for PrismLauncher installation
# @stdout      Path to the executable if found
# @return      0 if executable found, 1 if not found
# @example
#   if prism_exec=$(get_prism_executable); then
#       "$prism_exec" --help
#   fi
# -----------------------------------------------------------------------------
get_prism_executable() {
    if [[ -x "$PRISMLAUNCHER_DIR/squashfs-root/AppRun" ]]; then
        echo "$PRISMLAUNCHER_DIR/squashfs-root/AppRun"
    elif [[ -x "$PRISMLAUNCHER_DIR/PrismLauncher.AppImage" ]]; then
        echo "$PRISMLAUNCHER_DIR/PrismLauncher.AppImage"
    else
        return 1
    fi
}

# =============================================================================
# SYSTEM DETECTION FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    is_immutable_os
# @description Detects if the system is running an immutable/atomic Linux
#              distribution. These systems prefer Flatpak over AppImage for
#              better integration and updates.
#
#              Detected distributions:
#              - Bazzite, SteamOS, Fedora Silverblue/Kinoite/Atomic
#              - Universal Blue (Aurora, Bluefin), NixOS
#              - openSUSE MicroOS/Aeon/Kalpa, Endless OS
#              - Any ostree-based distribution
#
# @param       None
# @global      IMMUTABLE_OS_NAME - (output) Set to detected OS name or empty
# @return      0 if immutable OS detected, 1 otherwise
# @example
#   if is_immutable_os; then
#       echo "Running on $IMMUTABLE_OS_NAME"
#   fi
# -----------------------------------------------------------------------------
is_immutable_os() {
    IMMUTABLE_OS_NAME=""

    # Bazzite (based on Fedora Atomic)
    if [[ -f /etc/bazzite/image_name ]] || grep -qi "bazzite" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="Bazzite"
        return 0
    fi

    # SteamOS (Steam Deck)
    if [[ -f /etc/steamos-release ]] || grep -qi "steamos" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="SteamOS"
        return 0
    fi

    # Fedora Silverblue/Kinoite/Atomic
    if grep -qi "fedora" /etc/os-release 2>/dev/null; then
        if grep -qi "silverblue\|kinoite\|atomic\|ostree" /etc/os-release 2>/dev/null || \
           [[ -d /ostree ]] || rpm-ostree status &>/dev/null; then
            IMMUTABLE_OS_NAME="Fedora Atomic"
            return 0
        fi
    fi

    # Universal Blue variants (Aurora, Bluefin, etc.)
    if [[ -f /etc/ublue-os/image_name ]] || grep -qi "ublue\|aurora\|bluefin" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="Universal Blue"
        return 0
    fi

    # NixOS (immutable by design)
    if [[ -f /etc/NIXOS ]] || grep -qi "nixos" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="NixOS"
        return 0
    fi

    # openSUSE MicroOS/Aeon/Kalpa
    if grep -qi "microos\|aeon\|kalpa" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="openSUSE MicroOS"
        return 0
    fi

    # Endless OS
    if grep -qi "endless" /etc/os-release 2>/dev/null; then
        IMMUTABLE_OS_NAME="Endless OS"
        return 0
    fi

    # Generic ostree-based detection (catches other atomic distros)
    if [[ -d /ostree ]] && command -v ostree &>/dev/null; then
        IMMUTABLE_OS_NAME="ostree-based"
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# @function    should_prefer_flatpak
# @description Determines if Flatpak should be preferred over AppImage for
#              application installation. Returns true for immutable systems
#              or systems where Flatpak appears to be the primary package format.
# @param       None
# @return      0 if Flatpak preferred, 1 if AppImage preferred
# @example
#   if should_prefer_flatpak; then
#       flatpak install --user flathub org.prismlauncher.PrismLauncher
#   else
#       wget -O app.AppImage "$appimage_url"
#   fi
# -----------------------------------------------------------------------------
should_prefer_flatpak() {
    # Prefer Flatpak on immutable systems
    if is_immutable_os; then
        return 0
    fi

    # Also prefer Flatpak if it's the primary package manager
    if command -v flatpak &>/dev/null; then
        if ! command -v apt &>/dev/null && ! command -v dnf &>/dev/null && ! command -v pacman &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# OUTPUT FORMATTING FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    print_header
# @description Displays a prominent section header with visual separators.
# @param       $1 - Header text to display
# @stdout      Formatted header with separator lines
# @return      0 always
# @example
#   print_header "INSTALLING DEPENDENCIES"
# -----------------------------------------------------------------------------
print_header() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# -----------------------------------------------------------------------------
# @function    print_success
# @description Displays a success message with green checkmark emoji.
# @param       $1 - Success message text
# @stdout      Formatted success message
# @return      0 always
# -----------------------------------------------------------------------------
print_success() {
    echo "✅ $1"
}

# -----------------------------------------------------------------------------
# @function    print_warning
# @description Displays a warning message with yellow warning emoji.
# @param       $1 - Warning message text
# @stdout      Formatted warning message
# @return      0 always
# -----------------------------------------------------------------------------
print_warning() {
    echo "⚠️  $1"
}

# -----------------------------------------------------------------------------
# @function    print_error
# @description Displays an error message with red X emoji to stderr.
# @param       $1 - Error message text
# @stderr      Formatted error message
# @return      0 always
# -----------------------------------------------------------------------------
print_error() {
    echo "❌ $1" >&2
}

# -----------------------------------------------------------------------------
# @function    print_info
# @description Displays an informational message with lightbulb emoji.
# @param       $1 - Info message text
# @stdout      Formatted info message
# @return      0 always
# -----------------------------------------------------------------------------
print_info() {
    echo "💡 $1"
}

# -----------------------------------------------------------------------------
# @function    print_progress
# @description Displays a progress/in-progress message with spinner emoji.
# @param       $1 - Progress message text
# @stdout      Formatted progress message
# @return      0 always
# -----------------------------------------------------------------------------
print_progress() {
    echo "🔄 $1"
}

# =============================================================================
# ACCOUNT MANAGEMENT FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    merge_accounts_json
# @description Merges splitscreen player accounts (P1-P4) into an existing
#              accounts.json file while preserving any other accounts (e.g.,
#              Microsoft accounts). If jq is not available, falls back to
#              overwriting the destination file.
#
# @param       $1 - source_file: Path to accounts.json with P1-P4 accounts
# @param       $2 - dest_file: Path to destination accounts.json (created if missing)
#
# @return      0 on success (merge or copy completed)
#              1 on failure (source file not found)
#
# @example
#   merge_accounts_json "/tmp/splitscreen_accounts.json" "$HOME/.local/share/PrismLauncher/accounts.json"
#
# @note        Requires jq for proper merging. Without jq, existing accounts
#              will be overwritten with splitscreen accounts only.
# -----------------------------------------------------------------------------
merge_accounts_json() {
    local source_file="$1"
    local dest_file="$2"

    # Validate source file exists
    if [[ ! -f "$source_file" ]]; then
        print_error "Source accounts file not found: $source_file"
        return 1
    fi

    # If destination doesn't exist, just copy source
    if [[ ! -f "$dest_file" ]]; then
        cp "$source_file" "$dest_file"
        print_info "Created new accounts.json with splitscreen accounts"
        return 0
    fi

    # Check if jq is available for JSON merging
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "jq not installed - attempting basic merge"
        cp "$source_file" "$dest_file"
        print_warning "Existing accounts may have been overwritten (install jq for proper merging)"
        return 0
    fi

    # Extract player names from source (P1, P2, P3, P4)
    local splitscreen_names
    splitscreen_names=$(jq -r '.accounts[].profile.name' "$source_file" 2>/dev/null)

    # Create a temporary file for the merged result
    local temp_file
    temp_file=$(mktemp)

    # Merge accounts:
    # 1. Keep all existing accounts that are NOT P1-P4 (preserve Microsoft accounts, etc.)
    # 2. Add all accounts from source (P1-P4 splitscreen accounts)
    if jq -s '
        (.[0].accounts | map(.profile.name)) as $splitscreen_names |
        {
            "accounts": (
                (.[1].accounts // [] | map(select(.profile.name as $name | $splitscreen_names | index($name) | not))) +
                .[0].accounts
            ),
            "formatVersion": (.[1].formatVersion // .[0].formatVersion // 3)
        }
    ' "$source_file" "$dest_file" > "$temp_file" 2>/dev/null; then
        # Validate the merged JSON
        if jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$dest_file"
            print_success "Merged splitscreen accounts with existing accounts"
            return 0
        else
            print_warning "Merged JSON validation failed, using source file"
            rm -f "$temp_file"
            cp "$source_file" "$dest_file"
            return 0
        fi
    else
        print_warning "JSON merge failed, using source file"
        rm -f "$temp_file"
        cp "$source_file" "$dest_file"
        return 0
    fi
}
