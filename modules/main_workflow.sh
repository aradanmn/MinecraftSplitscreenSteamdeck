#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck Installer - Main Workflow Module
# =============================================================================
# 
# This module contains the main orchestration logic for the complete splitscreen
# installation process. It coordinates all the other modules and provides
# comprehensive status reporting and user guidance.
#
# Functions provided:
# - main: Primary function that orchestrates the complete installation process
#
# =============================================================================

# main: Primary function that orchestrates the complete splitscreen installation process
#
# INSTALLATION WORKFLOW:
# 1. WORKSPACE SETUP: Create directories and initialize environment
# 2. CORE SETUP: Java detection and PolyMC download
# 3. VERSION DETECTION: Minecraft and Fabric version determination
# 4. ACCOUNT SETUP: Download offline splitscreen player accounts
# 5. MOD COMPATIBILITY: Query APIs and determine compatible mod versions
# 6. USER SELECTION: Interactive mod selection interface
# 7. INSTANCE CREATION: Create 4 splitscreen instances with manual configuration
# 8. INTEGRATION: Optional Steam and desktop launcher integration
# 9. COMPLETION: Summary report and usage instructions
#
# ERROR HANDLING STRATEGY:
# - Each phase has fallback mechanisms to ensure installation can complete
# - Non-critical integration failures don't halt the entire process
# - Comprehensive error reporting helps users understand any issues
# - Multiple validation checkpoints ensure data integrity
#
# LAUNCHER APPROACH:
# The script uses PolyMC as the primary launcher for day-to-day splitscreen gameplay.
main() {
    # Support direct module testing calls with --debug.
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--debug" ]]; then
            DEBUG_MODE=true
        fi
    done

    # #27: mod-resolver debug output (see instance_creation.sh) accumulated indefinitely
    # in /tmp across every --debug run with nothing ever clearing it. Start each debug
    # run with a clean directory instead of piling up files from prior runs forever.
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        rm -rf "/tmp/mcss-debug-api" 2>/dev/null || true
    fi

    print_header "🎮 MINECRAFT SPLITSCREEN INSTALLER 🎮"
    print_info "PolyMC launcher setup with manual instance creation"
    print_debug "Debug logging enabled"
    echo ""
    
    # =============================================================================
    # WORKSPACE INITIALIZATION PHASE
    # =============================================================================
    
    # WORKSPACE SETUP: Create and navigate to working directory
    # All temporary files, downloads, and initial setup happen in TARGET_DIR
    # This provides a clean, isolated environment for the installation process
    print_progress "Initializing installation workspace: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    cd "$TARGET_DIR" || exit 1
    print_success "✅ Workspace initialized successfully"
    
    # =============================================================================
    # CORE SYSTEM REQUIREMENTS VALIDATION
    # =============================================================================

    # HARD STOP before downloading anything if the KDE/Plasma/KWin stack (or other
    # critical deps) is missing — the splitscreen windowing requires it (item G).
    # HARD STOP before downloading/installing anything if a required program or the
    # KDE/Plasma/KWin stack is missing. preflight.sh is now sourced by the installer entry,
    # so this always runs. On read-only SteamOS we CANNOT install system packages, so we
    # fail fast with a clear, distro-aware message (preflight prints the hint) instead of
    # trying to sudo/pacman anything. (bwrap is part of preflight's required set.)
    _preflight_deps install || exit 1

    download_prism_launcher        # Download PolyMC AppImage for splitscreen launcher usage
    
    # =============================================================================
    # VERSION DETECTION AND CONFIGURATION
    # =============================================================================
    
    get_minecraft_version         # Determine target Minecraft version (user choice or latest)
    detect_java                   # Automatically detect, install, and configure correct Java version for selected Minecraft version
    configure_polymc_defaults     # Write launcher defaults so Quick Setup wizard is skipped
    get_fabric_version           # Get compatible Fabric loader version from API
    get_lwjgl_version            # Detect appropriate LWJGL version for Minecraft version
    
    # =============================================================================
    # OFFLINE ACCOUNTS CONFIGURATION
    # =============================================================================
    
    print_progress "Setting up offline accounts for splitscreen gameplay..."
    print_debug "Downloading pre-configured offline accounts for Player 1-4"
    
    # OFFLINE ACCOUNTS DOWNLOAD: Get splitscreen player account configurations
    # These accounts enable splitscreen without requiring multiple Microsoft accounts
    # Each player (P1, P2, P3, P4) gets a separate offline profile for identification
    # #31/G6: this used to be a WARNING-only failure — accounts.json missing/invalid
    # doesn't break the installer, it breaks LAUNCH later (PolyMC has no P1-P4 profile
    # to select with `-a P{slot}`), with nothing tying that failure back to this step.
    # PolyMC reads accounts.json straight from TARGET_DIR (its own data dir) — there's
    # no later per-instance copy step to catch this, so it must be validated HERE.
    if ! wget -O accounts.json "${MCSS_REPO_RAW_URL}/accounts.json"; then
        print_warning "⚠️  Failed to download accounts.json from repository"
        print_info "   → Attempting to use local copy if available..."
        if [[ ! -f "accounts.json" ]]; then
            print_error "❌ No accounts.json found — this is required for splitscreen player accounts to work."
            exit 1
        fi
    else
        print_success "✅ Offline splitscreen accounts configured successfully"
        print_debug "${MCSS_ACCOUNT_PREFIX}1-${MCSS_ACCOUNT_PREFIX}${MCSS_MAX_PLAYERS} player accounts ready for offline gameplay"
    fi

    # #31/G6: one-instance install smoke test — a downloaded-but-corrupt/truncated
    # accounts.json (partial write, HTML error page saved as the file, etc.) passes the
    # `-f` check above but still leaves launch broken with no diagnostic tying it back
    # here. Validate it actually parses and has at least one profile before moving on.
    if command -v jq >/dev/null 2>&1; then
        # The launcher selects an account per slot via `-a P{slot}` (minecraftSplitscreen.sh
        # launchSlot), matching accounts.json's .accounts[].profile.name — verify every
        # ${MCSS_ACCOUNT_PREFIX}1..N profile is actually present, not just valid JSON.
        local _expected_profiles _missing_profiles
        _expected_profiles=$(seq 1 "$MCSS_MAX_PLAYERS" | jq -R --arg p "$MCSS_ACCOUNT_PREFIX" '$p + .' | jq -s .)
        _missing_profiles=$(jq -r --argjson expected "$_expected_profiles" '
            [.accounts[]?.profile.name] as $names
            | $expected - $names | join(", ")
        ' accounts.json 2>/dev/null)
        if [[ -z "$_missing_profiles" ]] && jq -e '.accounts | length > 0' accounts.json >/dev/null 2>&1; then
            print_debug "accounts.json smoke test passed (${MCSS_ACCOUNT_PREFIX}1-${MCSS_ACCOUNT_PREFIX}${MCSS_MAX_PLAYERS} profiles present)"
        else
            print_error "❌ accounts.json exists but failed validation (not valid JSON, or missing player profile(s): ${_missing_profiles:-all}) — splitscreen launches will fail to select a player account."
            exit 1
        fi
    fi

    # =============================================================================
    # MOD ECOSYSTEM SETUP PHASE
    # =============================================================================
    
    check_mod_compatibility       # Query Modrinth/CurseForge APIs for compatible versions
    select_user_mods             # Interactive mod selection interface with categories
    
    # =============================================================================
    # MINECRAFT INSTANCE CREATION PHASE
    # =============================================================================
    
    
    create_instances             # Create MCSS_MAX_PLAYERS splitscreen instances using manual configuration
    # The launcher + runtime modules ARE the product — if they don't land, the install has
    # FAILED; stop here instead of printing "success" downstream. (A from-main install 404s
    # here until the branch is promoted; use REPO_REF=<branch> to install from a branch.)
    setup_splitscreen_launcher_script || { print_error "❌ Failed to install the splitscreen launcher (minecraftSplitscreen.sh) — aborting."; exit 1; }
    install_runtime_modules || { print_error "❌ Failed to install the runtime modules — aborting; the launcher cannot run without them."; exit 1; }
    
    # =============================================================================
    # SYSTEM INTEGRATION PHASE: Optional platform integration
    # =============================================================================
    
    setup_steam_integration     # Add splitscreen launcher to Steam library (optional)
    create_desktop_launcher     # Create native desktop launcher and app menu entry (optional)
    
    # =============================================================================
    # INSTALLATION COMPLETION AND STATUS REPORTING
    # =============================================================================
    
    print_header "🎉 INSTALLATION COMPLETE"
    
    # =============================================================================
    # MISSING MODS ANALYSIS: Report any compatibility issues
    # =============================================================================
    
    # MISSING MODS REPORT: Alert user to any mods that couldn't be installed
    # This helps users understand if specific functionality might be unavailable
    # Common causes: no Fabric version available, API changes, temporary download issues
    local missing_count=0
    if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
        missing_count=${#MISSING_MODS[@]}
    fi
    if [[ $missing_count -gt 0 ]]; then
        echo ""
        print_warning "Some optional mods could not be installed:"
        for mod in "${MISSING_MODS[@]}"; do
            echo "  ❌ $mod"
        done
        print_info "Core splitscreen functionality will still work."
    fi
    
    # =============================================================================
    # FINAL SUCCESS MESSAGE AND NEXT STEPS
    # =============================================================================
    
    echo "✅ Installation successful"
    echo "Launcher: PolyMC"
    echo "Instances: $MCSS_MAX_PLAYERS (${MCSS_INSTANCE_PREFIX}1 to ${MCSS_INSTANCE_PREFIX}${MCSS_MAX_PLAYERS})"
    echo ""
    echo "Run: $TARGET_DIR/minecraftSplitscreen.sh"

    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo ""
        echo "Debug details"
        echo "- Installation dir: $TARGET_DIR"
        echo "- Launcher executable: $TARGET_DIR/PolyMC.AppImage"
        echo "- Instances dir: $TARGET_DIR/instances/"
        echo "- Accounts file: $TARGET_DIR/accounts.json"
    fi

    echo ""
    echo "For troubleshooting or updates, visit:"
    echo "https://github.com/aradanmn/MinecraftSplitscreenSteamdeck"
    echo "=========================================="
}
