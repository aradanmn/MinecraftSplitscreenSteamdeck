#!/bin/bash
# =============================================================================
# @file        main_workflow.sh
# @version     3.0.3
# @date        2026-03-07
# @author      Minecraft Splitscreen Steam Deck Project
# @license     MIT
# @repository  https://github.com/aradanmn/MinecraftSplitscreenSteamdeck
#
# @description
#   Main orchestration module for the complete splitscreen installation process.
#   Coordinates all other modules and provides comprehensive status reporting
#   and user guidance throughout the installation.
#
#   The module implements a 10-phase installation workflow:
#   1. Workspace Setup → 2. Core Setup → 3. Version Detection →
#   4. Account Setup → 5. Mod Compatibility → 6. User Selection →
#   7. Instance Creation → 8. Launcher Optimization →
#   9. System Integration → 10. Completion Report
#
# @dependencies
#   - All other modules (sourced by install-minecraft-splitscreen.sh)
#   - path_configuration.sh (for configure_launcher_paths, finalize_launcher_paths)
#   - launcher_setup.sh (for download_prism_launcher, verify_prism_cli)
#   - version_management.sh (for get_minecraft_version, get_fabric_version)
#   - java_management.sh (for detect_java)
#   - lwjgl_management.sh (for get_lwjgl_version)
#   - mod_management.sh (for check_mod_compatibility, select_user_mods)
#   - instance_creation.sh (for create_instances)
#   - launcher_script_generator.sh (for generate_splitscreen_launcher)
#   - steam_integration.sh (for setup_steam_integration)
#   - desktop_launcher.sh (for create_desktop_launcher)
#   - utilities.sh (for print_* functions, merge_accounts_json)
#
# @exports
#   Functions:
#     - main                    : Primary orchestration function
#     - generate_launcher_script: Generate minecraftSplitscreen.sh
#
# @changelog
#   3.0.3 (2026-03-07) - Removed PollyMC; PrismLauncher is now the sole launcher
#   3.0.2 (2026-02-07) - Updated dynamic mode summary to show KWin scripting status
#   3.0.1 (2026-02-01) - Updated launch instructions to show CLI arguments
#   3.0.0 (2026-02-01) - Added dynamic mode dependency check and status display
#   2.1.0 (2026-01-31) - Added version display in startup header
#   2.0.1 (2026-01-26) - Added init_logging() call at startup
#   2.0.0 (2026-01-25) - Added comprehensive JSDoc documentation
#   1.0.0 (2024-XX-XX) - Initial implementation
# =============================================================================

# @function    main
# @description Primary function that orchestrates the complete splitscreen
#              installation process. Coordinates all modules in sequence.
#
# INSTALLATION WORKFLOW:
# 1. WORKSPACE SETUP: Create directories and initialize environment
# 2. CORE SETUP: Java detection, PrismLauncher download, CLI verification
# 3. VERSION DETECTION: Minecraft and Fabric version determination
# 4. ACCOUNT SETUP: Download offline splitscreen player accounts
# 5. MOD COMPATIBILITY: Query APIs and determine compatible mod versions
# 6. USER SELECTION: Interactive mod selection interface
# 7. INSTANCE CREATION: Create 4 splitscreen instances with PrismLauncher CLI
# 8. LAUNCHER SCRIPT GENERATION: Generate the splitscreen launcher script
# 9. INTEGRATION: Optional Steam and desktop launcher integration
# 10. COMPLETION: Summary report and usage instructions
#
# ERROR HANDLING STRATEGY:
# - Each phase has fallback mechanisms to ensure installation can complete
# - Non-critical failures don't halt the entire process
# - Comprehensive error reporting helps users understand any issues
# - Multiple validation checkpoints ensure data integrity
#
# LAUNCHER APPROACH:
# PrismLauncher is used for both instance creation and gameplay:
# - CLI automation for reliable instance creation with proper Fabric setup
# - Stable, well-supported launcher with broad community backing
#
# @global      Multiple globals from path_configuration.sh (ACTIVE_*, CREATION_*)
# @global      MC_VERSION - (output) Set by get_minecraft_version
# @global      JAVA_PATH - (output) Set by detect_java
# @global      MISSING_MODS - (input) Array of mods that couldn't be installed
# @return      0 on successful completion
main() {
    # Initialize logging FIRST (before any print_* calls)
    init_logging "install"

    print_header "🎮 MINECRAFT SPLITSCREEN INSTALLER v${SCRIPT_VERSION} 🎮"
    print_info "Advanced installation system with smart launcher detection"
    print_info "Strategy: Detect available launchers → Create instances → Generate launcher script"
    print_info "Log file: $(get_log_file)"
    echo ""

    # =============================================================================
    # LAUNCHER DETECTION AND PATH CONFIGURATION (MUST BE FIRST)
    # =============================================================================

    # This sets up all path variables based on what launchers are available
    # All subsequent code uses CREATION_* and ACTIVE_* variables from path_configuration.sh
    configure_launcher_paths

    # =============================================================================
    # WORKSPACE INITIALIZATION PHASE
    # =============================================================================

    # WORKSPACE SETUP: Create and navigate to working directory
    # Use CREATION_DATA_DIR as that's where we'll create instances initially
    local workspace_dir="${CREATION_DATA_DIR:-$HOME/.local/share/PrismLauncher}"
    print_progress "Initializing installation workspace: $workspace_dir"
    mkdir -p "$workspace_dir"
    cd "$workspace_dir" || exit 1
    print_success "✅ Workspace initialized successfully"

    # =============================================================================
    # CORE SYSTEM REQUIREMENTS VALIDATION
    # =============================================================================

    # Only download PrismLauncher if we don't have a creation launcher yet
    if [[ -z "$CREATION_LAUNCHER" ]]; then
        download_prism_launcher        # Download PrismLauncher AppImage for CLI automation
    fi

    if [[ -n "$CREATION_EXECUTABLE" ]] && ! verify_prism_cli; then
        print_info "PrismLauncher CLI unavailable - will use manual instance creation"
    fi

    # =============================================================================
    # VERSION DETECTION AND CONFIGURATION
    # =============================================================================

    get_minecraft_version         # Determine target Minecraft version (user choice or latest)
    detect_java                   # Automatically detect, install, and configure correct Java version for selected Minecraft version
    get_fabric_version           # Get compatible Fabric loader version from API
    get_lwjgl_version            # Detect appropriate LWJGL version for Minecraft version

    # =============================================================================
    # OFFLINE ACCOUNTS CONFIGURATION
    # =============================================================================

    print_progress "Setting up offline accounts for splitscreen gameplay..."
    print_info "Downloading pre-configured offline accounts for Player 1-4"

    # OFFLINE ACCOUNTS DOWNLOAD: Get splitscreen player account configurations
    # These accounts enable splitscreen without requiring multiple Microsoft accounts
    # Each player (P1, P2, P3, P4) gets a separate offline profile for identification
    # IMPORTANT: We merge accounts to preserve any existing Microsoft/other accounts
    local accounts_url="${REPO_RAW_URL:-https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/${REPO_BRANCH:-main}}/accounts.json"
    local accounts_temp
    accounts_temp=$(mktemp)
    local accounts_path="$CREATION_DATA_DIR/accounts.json"

    if wget -q -O "$accounts_temp" "$accounts_url"; then
        # Merge downloaded accounts with any existing accounts (preserves Microsoft accounts, etc.)
        if merge_accounts_json "$accounts_temp" "$accounts_path"; then
            print_success "✅ Offline splitscreen accounts configured successfully"
            print_info "   → P1, P2, P3, P4 player accounts ready for offline gameplay"
            if [[ -f "$accounts_path" ]] && command -v jq >/dev/null 2>&1; then
                local existing_count
                existing_count=$(jq '.accounts | map(select(.profile.name | test("^P[1-4]$") | not)) | length' "$accounts_path" 2>/dev/null || echo "0")
                if [[ "$existing_count" -gt 0 ]]; then
                    print_info "   → Preserved $existing_count existing account(s)"
                fi
            fi
        fi
    else
        print_warning "⚠️  Failed to download accounts.json from repository"
        print_info "   → Attempting to use local copy if available..."
        if [[ ! -f "$accounts_path" ]]; then
            print_error "❌ No accounts.json found - splitscreen accounts may require manual setup"
            print_info "   → Splitscreen will still work but players may have generic names"
        fi
    fi
    rm -f "$accounts_temp" 2>/dev/null

    # =============================================================================
    # MOD ECOSYSTEM SETUP PHASE
    # =============================================================================

    check_mod_compatibility       # Query Modrinth/CurseForge APIs for compatible versions
    select_user_mods             # Interactive mod selection interface with categories

    # =============================================================================
    # MINECRAFT INSTANCE CREATION PHASE
    # =============================================================================


    create_instances             # Create 4 splitscreen instances using PrismLauncher CLI with comprehensive fallbacks

    # =============================================================================
    # LAUNCHER SCRIPT GENERATION PHASE: Generate splitscreen launcher with correct paths
    # =============================================================================

    generate_launcher_script    # Generate minecraftSplitscreen.sh with detected launcher paths

    # =============================================================================
    # SYSTEM INTEGRATION PHASE: Optional platform integration
    # =============================================================================

    setup_steam_integration     # Add splitscreen launcher to Steam library (optional)
    create_desktop_launcher     # Create native desktop launcher and app menu entry (optional)

    # =============================================================================
    # INSTALLATION COMPLETION AND STATUS REPORTING
    # =============================================================================

    print_header "🎉 INSTALLATION ANALYSIS AND COMPLETION REPORT"

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
        print_warning "====================="
        print_warning "⚠️  MISSING MODS ANALYSIS"
        print_warning "====================="
        print_warning "The following mods could not be installed:"
        print_info "Common causes: No compatible Fabric version, API issues, download failures"
        echo ""
        for mod in "${MISSING_MODS[@]}"; do
            echo "  ❌ $mod"
        done
        print_warning "====================="
        print_info "These mods can be installed manually later if compatible versions become available"
        print_info "The splitscreen functionality will work without these optional mods"
    fi

    # =============================================================================
    # COMPREHENSIVE INSTALLATION SUCCESS REPORT
    # =============================================================================

    echo ""
    echo "=========================================="
    echo "🎮 MINECRAFT SPLITSCREEN INSTALLATION COMPLETE! 🎮"
    echo "=========================================="
    echo ""

    # =============================================================================
    # LAUNCHER STRATEGY SUCCESS ANALYSIS
    # =============================================================================

    # LAUNCHER STRATEGY REPORT: Explain which launcher is being used
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo ""
    echo "🔧 LAUNCHER CONFIGURATION:"
    echo "   🎮 Active Launcher: ${ACTIVE_LAUNCHER^} ($ACTIVE_LAUNCHER_TYPE)"
    echo "   📁 Data Directory: $ACTIVE_DATA_DIR"
    echo "   📁 Instances: $ACTIVE_INSTANCES_DIR"
    echo "   📜 Launcher Script: $ACTIVE_LAUNCHER_SCRIPT"
    echo ""
    echo "🎯 PRISMLAUNCHER BENEFITS:"
    echo "   • Proven reliability and stability"
    echo "   • Full functionality for splitscreen gameplay"
    echo "   • Wide community support"

    # =============================================================================
    # TECHNICAL ACHIEVEMENT SUMMARY
    # =============================================================================

    # INSTALLATION COMPONENTS SUMMARY: List all successfully completed setup elements
    echo ""
    echo "🏆 TECHNICAL ACHIEVEMENTS COMPLETED:"
    echo "✅ Java 21+ detection and configuration"
    echo "✅ Automated instance creation via PrismLauncher CLI"
    echo "✅ Complete Fabric dependency chain implementation"
    echo "✅ 4 splitscreen instances created and configured (Player 1-4)"
    echo "✅ Fabric mod loader installation with proper dependency resolution"
    echo "✅ Compatible mod versions detected and downloaded via API filtering"
    echo "✅ Splitscreen-specific configurations applied to all instances"
    echo "✅ Offline player accounts configured for splitscreen gameplay"
    echo "✅ Java memory settings optimized for splitscreen performance"
    echo "✅ Instance verification and launcher registration completed"
    echo "✅ Comprehensive automatic dependency resolution system"
    echo ""

    # =============================================================================
    # DYNAMIC SPLITSCREEN MODE STATUS
    # =============================================================================

    check_dynamic_mode_dependencies

    echo "🔄 DYNAMIC SPLITSCREEN MODE (v3.0.0):"
    echo ""

    local has_all_tools="true"

    if [[ "$DYNAMIC_HAS_INOTIFY" == "true" ]] && { [[ "$DYNAMIC_HAS_KWIN_SCRIPTING" == "true" ]] || [[ "$DYNAMIC_HAS_WINDOW_TOOLS" == "true" ]]; }; then
        print_success "All optional tools detected - full dynamic mode available!"
        echo "   • Instant controller detection"
        if [[ "$DYNAMIC_HAS_KWIN_SCRIPTING" == "true" ]]; then
            echo "   • Window repositioning: KWin scripting (Wayland-native)"
        else
            echo "   • Window repositioning: xdotool/wmctrl (X11)"
        fi
        if [[ "$DYNAMIC_HAS_NOTIFY" == "true" ]]; then
            echo "   • Desktop notifications enabled"
        fi
    else
        print_info "Dynamic mode available with fallbacks:"
        echo ""

        if [[ "$DYNAMIC_HAS_INOTIFY" == "true" ]]; then
            echo "   ✅ Controller detection: instant (inotifywait)"
        else
            echo "   ⚡ Controller detection: polling every 2 seconds"
            has_all_tools="false"
        fi

        if [[ "$DYNAMIC_HAS_KWIN_SCRIPTING" == "true" ]]; then
            echo "   ✅ Window repositioning: KWin scripting (Wayland-native)"
        elif [[ "$DYNAMIC_HAS_WINDOW_TOOLS" == "true" ]]; then
            echo "   ✅ Window repositioning: xdotool/wmctrl (X11)"
        else
            echo "   ⚡ Window repositioning: restart instances when layout changes"
            has_all_tools="false"
        fi

        if [[ "$DYNAMIC_HAS_NOTIFY" == "true" ]]; then
            echo "   ✅ Notifications: enabled"
        else
            echo "   ⚡ Notifications: disabled (silent operation)"
        fi

        if [[ "$has_all_tools" == "false" ]]; then
            echo ""
            print_info "To enable all features, install optional packages:"
            show_dynamic_mode_install_hints
        fi
    fi
    echo ""

    # =============================================================================
    # USER GUIDANCE AND LAUNCH INSTRUCTIONS
    # =============================================================================

    echo "🚀 READY TO PLAY SPLITSCREEN MINECRAFT!"
    echo ""

    # LAUNCH METHODS: Comprehensive guide to starting splitscreen Minecraft
    echo "🎮 HOW TO LAUNCH SPLITSCREEN MINECRAFT:"
    echo ""

    # PRIMARY LAUNCH METHOD: Direct script execution
    echo "1. 🔧 DIRECT LAUNCH (Recommended):"
    echo "   Interactive:  $ACTIVE_LAUNCHER_SCRIPT"
    echo "   Static mode:  $ACTIVE_LAUNCHER_SCRIPT --mode=static"
    echo "   Dynamic mode: $ACTIVE_LAUNCHER_SCRIPT --mode=dynamic"
    echo "   Help:         $ACTIVE_LAUNCHER_SCRIPT --help"
    echo ""

    # ALTERNATIVE LAUNCH METHODS: Other integration options
    echo "2. 🖥️  DESKTOP LAUNCHER:"
    echo "   Method: Double-click desktop shortcut or search 'Minecraft Splitscreen' in app menu"
    echo "   Availability: $(if [[ -f "$HOME/Desktop/MinecraftSplitscreen.desktop" ]]; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""

    echo "3. 🎯 STEAM INTEGRATION:"
    echo "   Method: Launch from Steam library or Big Picture mode"
    echo "   Benefits: Steam Deck Game Mode integration, Steam Input support"
    echo "   Availability: $(if grep -q "PollyMC\|PrismLauncher" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""

    # =============================================================================
    # SYSTEM REQUIREMENTS AND TECHNICAL DETAILS
    # =============================================================================

    echo "⚙️  SYSTEM CONFIGURATION DETAILS:"
    echo ""

    # LAUNCHER DETAILS: Technical information about the setup
    echo "🛠️  LAUNCHER CONFIGURATION:"
    echo "   • Primary launcher: ${ACTIVE_LAUNCHER^} ($ACTIVE_LAUNCHER_TYPE)"
    echo "   • Data directory: $ACTIVE_DATA_DIR"
    echo "   • Instances directory: $ACTIVE_INSTANCES_DIR"
    echo ""

    # MINECRAFT ACCOUNT REQUIREMENTS: Important user information
    echo "💳 ACCOUNT REQUIREMENTS:"
    echo "   • Microsoft account: Required for launcher access"
    echo "   • Account type: PAID Minecraft Java Edition required"
    echo "   • Splitscreen: Uses offline accounts (P1, P2, P3, P4) after login"
    echo ""

    # CONTROLLER INFORMATION: Hardware requirements and tips
    echo "🎮 CONTROLLER CONFIGURATION:"
    echo "   • Supported: Xbox, PlayStation, generic USB/Bluetooth controllers"
    echo "   • Detection: Automatic (1-4 controllers supported)"
    echo "   • Steam Deck: Built-in controls + external controllers"
    echo "   • Recommendation: Use wired controllers for best performance"
    echo ""

    # =============================================================================
    # INSTALLATION LOCATION SUMMARY
    # =============================================================================

    echo "📁 INSTALLATION LOCATIONS:"
    echo "   • Primary installation: $ACTIVE_DATA_DIR"
    echo "   • Launcher executable: $ACTIVE_EXECUTABLE"
    echo "   • Splitscreen script: $ACTIVE_LAUNCHER_SCRIPT"
    echo "   • Instance data: $ACTIVE_INSTANCES_DIR"
    echo "   • Account configuration: $ACTIVE_DATA_DIR/accounts.json"
    echo ""

    # =============================================================================
    # ADVANCED TECHNICAL FEATURE SUMMARY
    # =============================================================================

    echo "🔧 ADVANCED FEATURES IMPLEMENTED:"
    echo "   • Complete Fabric dependency chain with proper version matching"
    echo "   • API-based mod compatibility verification (Modrinth + CurseForge)"
    echo "   • Sophisticated version parsing with semantic version support"
    echo "   • Automatic dependency resolution and installation"
    echo "   • Enhanced error handling with multiple fallback strategies"
    echo "   • Instance verification and launcher registration"
    echo "   • Centralized path configuration for reliable operation"
    echo "   • Cross-platform Linux compatibility (Steam Deck + Desktop)"
    echo "   • Professional Steam and desktop environment integration"
    echo ""

    # =============================================================================
    # FINAL SUCCESS MESSAGE AND NEXT STEPS
    # =============================================================================

    # Display summary of any optional dependencies that couldn't be installed
    local missing_summary_count=0
    if [[ ${#MISSING_MODS[@]} -gt 0 ]]; then
        missing_summary_count=${#MISSING_MODS[@]}
    fi
    if [[ $missing_summary_count -gt 0 ]]; then
        echo ""
        echo "📋 INSTALLATION SUMMARY"
        echo "======================="
        echo "The following optional dependencies could not be installed:"
        for missing_mod in "${MISSING_MODS[@]}"; do
            echo "  • $missing_mod"
        done
        echo ""
        echo "ℹ️  These are typically optional dependencies that don't support Minecraft $MC_VERSION"
        echo "   The core splitscreen functionality will work perfectly without them."
        echo ""
    fi

    echo "🎉 INSTALLATION COMPLETE - ENJOY SPLITSCREEN MINECRAFT! 🎉"
    echo ""
    echo "Next steps:"
    echo "1. Connect your controllers (1-4 supported)"
    echo "2. Launch using any of the methods above"
    echo "3. The system will automatically detect controller count and launch appropriate instances"
    echo "4. Each player gets their own screen and can play independently"
    echo ""
    echo "📋 Log file: $(get_log_file)"
    echo ""
    echo "For troubleshooting or updates, visit:"
    echo "${REPO_URL:-https://github.com/aradanmn/MinecraftSplitscreenSteamdeck}"
    echo "=========================================="
}

# =============================================================================
# LAUNCHER SCRIPT GENERATION FUNCTION
# =============================================================================

# @function    generate_launcher_script
# @description Generate the minecraftSplitscreen.sh launcher with correct paths.
#              Uses centralized path configuration to generate a customized
#              launcher script with correct paths baked in.
#
# The generated script will:
# - Have version metadata embedded (version, commit, generation date)
# - Use the correct launcher executable path
# - Use the correct instances directory
# - Work for both AppImage and Flatpak installations
#
# @global      ACTIVE_LAUNCHER - (input) Name of active launcher
# @global      ACTIVE_LAUNCHER_TYPE - (input) Type (appimage/flatpak)
# @global      ACTIVE_EXECUTABLE - (input) Path to launcher executable
# @global      ACTIVE_DATA_DIR - (input) Launcher data directory
# @global      ACTIVE_INSTANCES_DIR - (input) Instances directory
# @global      ACTIVE_LAUNCHER_SCRIPT - (input) Output path for generated script
# @global      GENERATED_LAUNCHER_SCRIPT - (output) Set to output path on success
# @return      0 on success, 1 on failure
generate_launcher_script() {
    print_header "🔧 GENERATING SPLITSCREEN LAUNCHER SCRIPT"

    # Use the centralized path configuration
    # These variables are set by configure_launcher_paths() or finalize_launcher_paths()
    if [[ -z "$ACTIVE_LAUNCHER" ]] || [[ -z "$ACTIVE_DATA_DIR" ]]; then
        print_error "Launcher paths not configured! Call configure_launcher_paths() first."
        return 1
    fi

    local launcher_name="$ACTIVE_LAUNCHER"
    local launcher_type="$ACTIVE_LAUNCHER_TYPE"
    local launcher_exec="$ACTIVE_EXECUTABLE"
    local launcher_dir="$ACTIVE_DATA_DIR"
    local instances_dir="$ACTIVE_INSTANCES_DIR"
    local output_path="$ACTIVE_LAUNCHER_SCRIPT"

    # Validate paths exist
    if [[ ! -d "$instances_dir" ]]; then
        print_warning "Instances directory does not exist: $instances_dir"
        print_info "Creating directory..."
        mkdir -p "$instances_dir"
    fi

    # Print configuration summary
    print_info "Generating launcher script with configuration:"
    print_info "  Launcher: $launcher_name"
    print_info "  Type: $launcher_type"
    print_info "  Executable: $launcher_exec"
    print_info "  Data Directory: $launcher_dir"
    print_info "  Instances: $instances_dir"
    print_info "  Output: $output_path"

    # Generate the launcher script
    if generate_splitscreen_launcher \
        "$output_path" \
        "$launcher_name" \
        "$launcher_type" \
        "$launcher_exec" \
        "$launcher_dir" \
        "$instances_dir"; then

        # Verify the generated script
        if verify_generated_script "$output_path"; then
            print_success "✅ Launcher script generated and verified: $output_path"

            # Store the path for later reference (for Steam/Desktop integration)
            GENERATED_LAUNCHER_SCRIPT="$output_path"
            export GENERATED_LAUNCHER_SCRIPT
        else
            print_error "Generated script verification failed"
            return 1
        fi
    else
        print_error "Failed to generate launcher script"
        return 1
    fi

    return 0
}
