#!/bin/bash
# =============================================================================
# VERSION INFORMATION MODULE
# =============================================================================
# @file        version_info.sh
# @version     3.1.1
# @date        2026-03-15
# @author      aradanmn
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Provides version constants, repository information, and version utility
#   functions used throughout the installer and generated scripts. This module
#   is the single source of truth for versioning information.
#
# @dependencies
#   - git (optional, for commit hash detection)
#   - date (for timestamp generation)
#
# @exports
#   Constants:
#     - SCRIPT_VERSION   : Current version (semver format)
#     - REPO_OWNER       : GitHub repository owner
#     - REPO_NAME        : GitHub repository name
#     - REPO_BRANCH      : Active branch for downloads
#     - REPO_URL         : Full repository URL
#     - REPO_RAW_URL     : Raw content URL for file downloads
#     - REPO_MODULES_URL : URL for modules directory
#
#   Functions:
#     - get_commit_hash        : Get current git commit (short)
#     - get_timestamp          : Get ISO 8601 timestamp
#     - generate_version_header: Generate script header block
#     - print_version_info     : Print version to stdout
#     - verify_repo_source     : Verify running from expected repo
#
# @changelog
#   3.1.0 (2026-03-07) - Release: v3.1.0 — dynamic splitscreen stable, zombie/race fixes, pauseOnLostFocus, PrismLauncher-only
#   3.0.8 (2026-02-08) - Fix: SSH session detection, stop killing plasmashell, FullArea KWin, WAYLAND_DISPLAY check
#   3.0.5 (2026-02-07) - KWin scripting for Wayland window management
#   3.0.0 (2026-02-01) - Dynamic splitscreen: players can join/leave mid-session
#   2.1.0 (2026-01-31) - Updated SCRIPT_VERSION to 2.1.0 for rev2 release
#   2.0.0 (2026-01-24) - Updated for modular installer architecture
#   1.0.0 (2026-01-22) - Initial version
# =============================================================================

# =============================================================================
# VERSION CONSTANTS
# =============================================================================

# Script version - update this when making releases
readonly SCRIPT_VERSION="3.1.0"

# Repository information
readonly REPO_OWNER="aradanmn"
readonly REPO_NAME="MinecraftSplitscreenSteamdeck"
readonly REPO_BRANCH="main"

# Derived URLs
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
readonly REPO_MODULES_URL="${REPO_RAW_URL}/modules"

# =============================================================================
# VERSION UTILITY FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
# @function    get_commit_hash
# @description Returns the current git commit hash in short form (7 characters).
#              Returns "unknown" if not in a git repository or git unavailable.
# @param       None
# @stdout      Short commit hash or "unknown"
# @return      0 always
# @example
#   commit=$(get_commit_hash)
#   echo "Current commit: $commit"
# -----------------------------------------------------------------------------
get_commit_hash() {
    if command -v git >/dev/null 2>&1; then
        git rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# -----------------------------------------------------------------------------
# @function    get_timestamp
# @description Returns the current timestamp in ISO 8601 format.
# @param       None
# @stdout      ISO 8601 formatted timestamp (e.g., 2026-01-24T14:30:00-06:00)
# @return      0 always
# -----------------------------------------------------------------------------
get_timestamp() {
    date -Iseconds 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S%z"
}
