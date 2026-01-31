#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# @file        utilities.sh
# @version     3.0.0
# @date        2026-01-26
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Core utility functions for the Minecraft Splitscreen installer.
#   Provides logging, output formatting, user input handling, system detection,
#   and account management functionality used by all other modules.
#
#   LOGGING: All print_* functions automatically log to file. The log() function
#   is for debug info that shouldn't clutter the terminal.
#
# @dependencies
#   - jq (optional, for JSON merging - falls back to overwrite if missing)
#   - flatpak (optional, for Flatpak preference detection)
#   - ostree (optional, for immutable OS detection)
#
# @exports
#   Functions:
#     - init_logging            : Initialize logging system (call first in main)
#     - log                     : Write debug info to log only (not terminal)
#     - get_log_file            : Get current log file path
#     - prompt_user             : Get user input (works with curl | bash)
#     - prompt_yes_no           : Simplified yes/no prompts
#     - get_prism_executable    : Locate PrismLauncher executable
#     - is_immutable_os         : Detect immutable Linux distributions
#     - should_prefer_flatpak   : Determine preferred package format
#     - print_header            : Display section headers (auto-logs)
#     - print_success           : Display success messages (auto-logs)
#     - print_warning           : Display warning messages (auto-logs)
#     - print_error             : Display error messages (auto-logs)
#     - print_info              : Display info messages (auto-logs)
#     - print_progress          : Display progress messages (auto-logs)
#     - merge_accounts_json     : Merge Minecraft account configurations
#
#   Variables:
#     - LOG_FILE                : Current log file path (set by init_logging)
#     - LOG_DIR                 : Log directory path
#     - IMMUTABLE_OS_NAME       : Set by is_immutable_os() with detected OS name
#
# @changelog
#   1.2.0 (2026-01-26) - Added logging system, prompt_user for curl|bash support
#   1.1.0 (2026-01-24) - Added immutable OS detection and Flatpak preference
#   1.0.0 (2026-01-23) - Initial version with print functions and account merging
# =============================================================================

# =============================================================================
# LOGGING SYSTEM
# =============================================================================
# Logging is automatic - all print_* functions log to file.
# Use log() directly only for debug info that shouldn't show in terminal.

LOG_FILE=""
LOG_DIR="$HOME/.local/share/MinecraftSplitscreen/logs"
LOG_MAX_FILES=10

# -----------------------------------------------------------------------------
# @function    init_logging
# @description Initialize logging. Creates log directory, rotates old logs,
#              and logs system info. Call at the start of main().
# @param       $1 - Log type: "install" or "launcher" (default: "install")
# -----------------------------------------------------------------------------
init_logging() {
    local log_type="${1:-install}"
    local timestamp
    timestamp=$(date +%Y-%m-%d-%H%M%S)

    mkdir -p "$LOG_DIR" 2>/dev/null || {
        LOG_DIR="/tmp/MinecraftSplitscreen/logs"
        mkdir -p "$LOG_DIR"
    }

    LOG_FILE="$LOG_DIR/${log_type}-${timestamp}.log"

    # Rotate old logs (keep last N)
    local count=0
    while IFS= read -r file; do
        count=$((count + 1))
        [[ $count -gt $LOG_MAX_FILES ]] && rm -f "$file" 2>/dev/null
    done < <(ls -t "$LOG_DIR"/${log_type}-*.log 2>/dev/null)

    # Write log header
    {
        echo "================================================================================"
        echo "Minecraft Splitscreen ${log_type^} Log"
        echo "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "================================================================================"
        echo ""
        echo "=== SYSTEM INFO ==="
        echo "User: $(whoami)"
        echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
        [[ -f /etc/os-release ]] && grep -E '^(PRETTY_NAME|ID)=' /etc/os-release 2>/dev/null
        echo "Kernel: $(uname -r 2>/dev/null)"
        echo "Arch: $(uname -m 2>/dev/null)"
        echo ""
        echo "=== ENVIRONMENT ==="
        echo "DISPLAY: ${DISPLAY:-not set}"
        echo "XDG_SESSION_TYPE: ${XDG_SESSION_TYPE:-not set}"
        echo "STEAM_DECK: ${STEAM_DECK:-not set}"
        echo ""
        echo "================================================================================"
        echo ""
    } >> "$LOG_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# @function    log
# @description Write debug info to log file ONLY (not terminal). Use for
#              verbose details that help debugging but clutter the screen.
# -----------------------------------------------------------------------------
log() {
    [[ -n "$LOG_FILE" ]] && echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# @function    get_log_file
# @description Returns the current log file path.
# -----------------------------------------------------------------------------
get_log_file() {
    echo "$LOG_FILE"
}

# =============================================================================
# USER INPUT HANDLING
# =============================================================================
# These functions work both in normal execution AND curl | bash mode.

# -----------------------------------------------------------------------------
# @function    prompt_user
# @description Get user input. Works with curl | bash by reopening /dev/tty.
# @param       $1 - Prompt text
# @param       $2 - Default value
# @param       $3 - Timeout in seconds (default: 30, 0 for none)
# @stdout      User's response (or default)
# -----------------------------------------------------------------------------
prompt_user() {
    local prompt="$1"
    local default="${2:-}"
    local timeout="${3:-30}"
    local response saved_stdin

    log "PROMPT: $prompt (default: $default, timeout: ${timeout}s)"

    # Reopen /dev/tty if stdin isn't a terminal (curl | bash case)
    if [[ ! -t 0 ]]; then
        if [[ -e /dev/tty ]]; then
            exec {saved_stdin}<&0
            exec 0</dev/tty
            log "Reopened /dev/tty for input"
        else
            log "No /dev/tty available, using default"
            echo "$default"
            return 1
        fi
    fi

    if [[ "$timeout" -gt 0 ]]; then
        read -r -t "$timeout" -p "$prompt" response || { echo ""; response="$default"; }
    else
        read -r -p "$prompt" response
    fi

    # Restore stdin if changed
    [[ -n "${saved_stdin:-}" ]] && { exec 0<&"$saved_stdin"; exec {saved_stdin}<&-; }

    response="${response:-$default}"
    log "USER INPUT: $response"
    echo "$response"
}

# -----------------------------------------------------------------------------
# @function    prompt_yes_no
# @description Simple yes/no prompt.
# @param       $1 - Question
# @param       $2 - Default: "y" or "n" (default: "n")
# @return      0 if yes, 1 if no
# -----------------------------------------------------------------------------
prompt_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local prompt_text response

    [[ "${default,,}" == "y" ]] && prompt_text="$question [Y/n]: " || prompt_text="$question [y/N]: "
    response=$(prompt_user "$prompt_text" "$default" 30)

    [[ "${response,,}" =~ ^y(es)?$ ]] && return 0 || return 1
}

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
    log "========== $1 =========="
}

# -----------------------------------------------------------------------------
# @function    print_success
# @description Displays a success message with green checkmark emoji. Auto-logs.
# @param       $1 - Success message text
# @stdout      Formatted success message
# @return      0 always
# -----------------------------------------------------------------------------
print_success() {
    echo "✅ $1"
    log "SUCCESS: $1"
}

# -----------------------------------------------------------------------------
# @function    print_warning
# @description Displays a warning message with yellow warning emoji. Auto-logs.
# @param       $1 - Warning message text
# @stdout      Formatted warning message
# @return      0 always
# -----------------------------------------------------------------------------
print_warning() {
    echo "⚠️  $1"
    log "WARNING: $1"
}

# -----------------------------------------------------------------------------
# @function    print_error
# @description Displays an error message with red X emoji to stderr. Auto-logs.
# @param       $1 - Error message text
# @stderr      Formatted error message
# @return      0 always
# -----------------------------------------------------------------------------
print_error() {
    echo "❌ $1" >&2
    log "ERROR: $1"
}

# -----------------------------------------------------------------------------
# @function    print_info
# @description Displays an informational message with lightbulb emoji. Auto-logs.
# @param       $1 - Info message text
# @stdout      Formatted info message
# @return      0 always
# -----------------------------------------------------------------------------
print_info() {
    echo "💡 $1"
    log "INFO: $1"
}

# -----------------------------------------------------------------------------
# @function    print_progress
# @description Displays a progress/in-progress message with spinner emoji. Auto-logs.
# @param       $1 - Progress message text
# @stdout      Formatted progress message
# @return      0 always
# -----------------------------------------------------------------------------
print_progress() {
    echo "🔄 $1"
    log "PROGRESS: $1"
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
