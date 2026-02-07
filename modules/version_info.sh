#!/bin/bash
# =============================================================================
# VERSION INFORMATION MODULE
# =============================================================================
# @file        version_info.sh
# @version     3.0.7
# @date        2026-02-07
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
readonly SCRIPT_VERSION="3.0.7"

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

# -----------------------------------------------------------------------------
# @function    generate_version_header
# @description Generates a standardized version header block for auto-generated
#              scripts. Includes version, commit, timestamp, and source info.
# @param       $1 - script_name: Name of the script (default: "unknown")
# @param       $2 - description: Brief description (default: "Auto-generated script")
# @stdout      Multi-line header block suitable for bash scripts
# @return      0 always
# @example
#   generate_version_header "minecraftSplitscreen.sh" "Minecraft Splitscreen Launcher"
# -----------------------------------------------------------------------------
generate_version_header() {
    local script_name="${1:-unknown}"
    local description="${2:-Auto-generated script}"
    local commit_hash
    local timestamp

    commit_hash=$(get_commit_hash)
    timestamp=$(get_timestamp)

    cat << EOF
# =============================================================================
# ${description}
# =============================================================================
# Version: ${SCRIPT_VERSION} (commit: ${commit_hash})
# Generated: ${timestamp}
# Generator: install-minecraft-splitscreen.sh v${SCRIPT_VERSION}
# Source: ${REPO_URL}
#
# DO NOT EDIT - This file is auto-generated by the installer.
# To update, re-run the installer script.
# =============================================================================
EOF
}

# -----------------------------------------------------------------------------
# @function    print_version_info
# @description Prints human-readable version information to stdout. Useful for
#              --version flags or debugging output.
# @param       None
# @stdout      Formatted version information
# @return      0 always
# -----------------------------------------------------------------------------
print_version_info() {
    local commit_hash
    commit_hash=$(get_commit_hash)

    echo "Minecraft Splitscreen Installer"
    echo "Version: ${SCRIPT_VERSION} (commit: ${commit_hash})"
    echo "Repository: ${REPO_URL}"
    echo "Branch: ${REPO_BRANCH}"
}

# -----------------------------------------------------------------------------
# @function    verify_repo_source
# @description Verifies that the script is running from the expected repository.
#              Prints a warning if running from a different repository but does
#              not fail (allows forks and local modifications).
# @param       None
# @stderr      Warning message if repository mismatch
# @return      0 if matches or cannot verify, 1 if mismatch detected
# -----------------------------------------------------------------------------
verify_repo_source() {
    if ! command -v git >/dev/null 2>&1; then
        return 0
    fi

    local remote_url
    remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")

    if [[ -z "$remote_url" ]]; then
        return 0
    fi

    if echo "$remote_url" | grep -qi "${REPO_OWNER}/${REPO_NAME}"; then
        return 0
    fi

    echo "[Warning] Running from a different repository: $remote_url" >&2
    echo "[Warning] Expected: ${REPO_URL}" >&2
    return 1
}
