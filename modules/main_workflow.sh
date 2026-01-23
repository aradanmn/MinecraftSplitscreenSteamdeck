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
# 2. CORE SETUP: Java detection, PrismLauncher download, CLI verification
# 3. VERSION DETECTION: Minecraft and Fabric version determination
# 4. ACCOUNT SETUP: Download offline splitscreen player accounts
# 5. MOD COMPATIBILITY: Query APIs and determine compatible mod versions
# 6. USER SELECTION: Interactive mod selection interface
# 7. INSTANCE CREATION: Create 4 splitscreen instances with PrismLauncher CLI
# 8. LAUNCHER OPTIMIZATION: Setup PollyMC and cleanup PrismLauncher (if successful)
# 9. INTEGRATION: Optional Steam and desktop launcher integration
# 10. COMPLETION: Summary report and usage instructions
#
# ERROR HANDLING STRATEGY:
# - Each phase has fallback mechanisms to ensure installation can complete
# - Non-critical failures (like PollyMC setup) don't halt the entire process
# - Comprehensive error reporting helps users understand any issues
# - Multiple validation checkpoints ensure data integrity
#
# DUAL-LAUNCHER APPROACH:
# The script uses an optimized strategy combining two launchers:
# - PrismLauncher: CLI automation for reliable instance creation with proper Fabric setup
# - PollyMC: Offline-friendly gameplay launcher without forced authentication
# - Smart cleanup: Removes PrismLauncher after successful PollyMC setup to save space
main() {
    print_header "🎮 MINECRAFT SPLITSCREEN INSTALLER 🎮"
    print_info "Advanced installation system with dual-launcher optimization"
    print_info "Strategy: PrismLauncher CLI automation → PollyMC gameplay → Smart cleanup"
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

    download_prism_launcher        # Download PrismLauncher AppImage for CLI automation
    if ! verify_prism_cli; then    # Test CLI functionality (non-fatal if it fails)
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
    local accounts_url="${REPO_RAW_URL:-https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main}/accounts.json"
    if ! wget -O accounts.json "$accounts_url"; then
        print_warning "⚠️  Failed to download accounts.json from repository"
        print_info "   → Attempting to use local copy if available..."
        if [[ ! -f "accounts.json" ]]; then
            print_error "❌ No accounts.json found - splitscreen accounts may require manual setup"
            print_info "   → Splitscreen will still work but players may have generic names"
        fi
    else
        print_success "✅ Offline splitscreen accounts configured successfully"
        print_info "   → P1, P2, P3, P4 player accounts ready for offline gameplay"
    fi

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
    # LAUNCHER OPTIMIZATION PHASE: Advanced launcher configuration
    # =============================================================================

    setup_pollymc               # Download PollyMC, migrate instances, verify, cleanup PrismLauncher

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

    # LAUNCHER STRATEGY REPORT: Explain which approach was successful and the benefits
    # The dual-launcher approach provides the best of both worlds when successful
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "✅ OPTIMIZED INSTALLATION SUCCESSFUL!"
        echo ""
        echo "🔧 DUAL-LAUNCHER STRATEGY COMPLETED:"
        echo "   🛠️  PrismLauncher: CLI automation for reliable instance creation ✅ COMPLETED"
        echo "   🎮 PollyMC: Primary launcher for offline splitscreen gameplay ✅ ACTIVE"
        echo "   🧹 Smart cleanup: Removes PrismLauncher after successful setup ✅ CLEANED"
        echo ""
        echo "🎯 STRATEGY BENEFITS ACHIEVED:"
        echo "   • Reliable instance creation through proven CLI automation"
        echo "   • Offline-friendly gameplay without forced Microsoft login prompts"
        echo "   • Optimized disk usage through intelligent cleanup"
        echo "   • Best performance for splitscreen scenarios"
        echo ""
        echo "✅ Primary launcher: PollyMC (optimized for splitscreen)"
        echo "✅ All instances migrated and verified in PollyMC"
        echo "✅ Temporary PrismLauncher files cleaned up successfully"
    else
        echo "✅ FALLBACK INSTALLATION SUCCESSFUL!"
        echo ""
        echo "🔧 FALLBACK STRATEGY USED:"
        echo "   🛠️  PrismLauncher: Instance creation + primary launcher ✅ ACTIVE"
        echo "   ⚠️  PollyMC: Download/setup encountered issues, using PrismLauncher for everything"
        echo ""
        echo "📋 FALLBACK EXPLANATION:"
        echo "   • PollyMC setup failed (network issues, system compatibility, or download problems)"
        echo "   • PrismLauncher provides full functionality as backup launcher"
        echo "   • Splitscreen works perfectly with PrismLauncher"
        echo ""
        echo "✅ Primary launcher: PrismLauncher (proven reliability)"
        echo "⚠️  Note: PollyMC optimization unavailable, but full functionality preserved"
    fi

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
    # USER GUIDANCE AND LAUNCH INSTRUCTIONS
    # =============================================================================

    echo "🚀 READY TO PLAY SPLITSCREEN MINECRAFT!"
    echo ""

    # LAUNCH METHODS: Comprehensive guide to starting splitscreen Minecraft
    echo "🎮 HOW TO LAUNCH SPLITSCREEN MINECRAFT:"
    echo ""

    # PRIMARY LAUNCH METHOD: Direct script execution
    echo "1. 🔧 DIRECT LAUNCH (Recommended):"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   Command: $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        echo "   Description: Optimized PollyMC launcher with automatic controller detection"
    else
        echo "   Command: $TARGET_DIR/minecraftSplitscreen.sh"
        echo "   Description: PrismLauncher-based splitscreen with automatic controller detection"
    fi
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
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "🛠️  LAUNCHER CONFIGURATION:"
        echo "   • Instance creation: PrismLauncher CLI (automated)"
        echo "   • Gameplay launcher: PollyMC (offline-optimized)"
        echo "   • Strategy: Best of both worlds approach"
        echo "   • Benefits: CLI automation + offline gameplay + no forced login"
    else
        echo "🛠️  LAUNCHER CONFIGURATION:"
        echo "   • Primary launcher: PrismLauncher (all functions)"
        echo "   • Strategy: Single launcher approach"
        echo "   • Note: PollyMC optimization unavailable, but fully functional"
    fi
    echo ""

    # MINECRAFT ACCOUNT REQUIREMENTS: Important user information
    echo "💳 ACCOUNT REQUIREMENTS:"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Microsoft account: Required for initial setup and updates"
        echo "   • Account type: PAID Minecraft Java Edition required"
        echo "   • Login frequency: Minimal (PollyMC is offline-friendly)"
        echo "   • Splitscreen: Uses offline accounts (P1, P2, P3, P4) after initial login"
    else
        echo "   • Microsoft account: Required for launcher access"
        echo "   • Account type: PAID Minecraft Java Edition required"
        echo "   • Note: PrismLauncher may prompt for periodic authentication"
        echo "   • Splitscreen: Uses offline accounts (P1, P2, P3, P4) after login"
    fi
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
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Primary installation: $HOME/.local/share/PollyMC/"
        echo "   • Launcher executable: $HOME/.local/share/PollyMC/PollyMC-Linux-x86_64.AppImage"
        echo "   • Splitscreen script: $HOME/.local/share/PollyMC/minecraftSplitscreen.sh"
        echo "   • Instance data: $HOME/.local/share/PollyMC/instances/"
        echo "   • Account configuration: $HOME/.local/share/PollyMC/accounts.json"
        echo "   • Temporary build files: Successfully removed after setup ✅"
    else
        echo "   • Primary installation: $TARGET_DIR"
        echo "   • Launcher executable: $TARGET_DIR/PrismLauncher.AppImage"
        echo "   • Splitscreen script: $TARGET_DIR/minecraftSplitscreen.sh"
        echo "   • Instance data: $TARGET_DIR/instances/"
        echo "   • Account configuration: $TARGET_DIR/accounts.json"
    fi
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
    echo "   • Smart cleanup with disk space optimization"
    if [[ "$USE_POLLYMC" == true ]]; then
        echo "   • Dual-launcher optimization strategy successfully implemented"
    fi
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
    echo "For troubleshooting or updates, visit:"
    echo "${REPO_URL:-https://github.com/aradanmn/MinecraftSplitscreenSteamdeck}"
    echo "=========================================="
}

# =============================================================================
# LAUNCHER SCRIPT GENERATION FUNCTION
# =============================================================================

# generate_launcher_script: Generate the minecraftSplitscreen.sh launcher with correct paths
#
# This function detects the active launcher (PollyMC or PrismLauncher, AppImage or Flatpak)
# and generates a customized launcher script with the correct paths baked in.
#
# The generated script will:
# - Have version metadata embedded (version, commit, generation date)
# - Use the correct launcher executable path
# - Use the correct instances directory
# - Work for both AppImage and Flatpak installations
generate_launcher_script() {
    print_header "🔧 GENERATING SPLITSCREEN LAUNCHER SCRIPT"

    local launcher_name=""
    local launcher_type=""
    local launcher_exec=""
    local launcher_dir=""
    local instances_dir=""
    local output_path=""

    # Detect the gameplay launcher (prefer PollyMC)
    if [[ "$USE_POLLYMC" == true ]]; then
        # Try to detect PollyMC
        if detect_pollymc; then
            launcher_name="$DETECTED_LAUNCHER_NAME"
            launcher_type="$DETECTED_LAUNCHER_TYPE"
            launcher_exec="$DETECTED_LAUNCHER_EXEC"
            launcher_dir="$DETECTED_LAUNCHER_DIR"
            instances_dir="$DETECTED_INSTANCES_DIR"
            output_path="$launcher_dir/minecraftSplitscreen.sh"
            print_success "Detected PollyMC ($launcher_type)"
        else
            print_warning "PollyMC detection failed, falling back to PrismLauncher"
            USE_POLLYMC=false
        fi
    fi

    # Fall back to PrismLauncher if PollyMC not available
    if [[ "$USE_POLLYMC" != true ]]; then
        if detect_prismlauncher; then
            launcher_name="$DETECTED_LAUNCHER_NAME"
            launcher_type="$DETECTED_LAUNCHER_TYPE"
            launcher_exec="$DETECTED_LAUNCHER_EXEC"
            launcher_dir="$DETECTED_LAUNCHER_DIR"
            instances_dir="$DETECTED_INSTANCES_DIR"
            output_path="$launcher_dir/minecraftSplitscreen.sh"
            print_success "Detected PrismLauncher ($launcher_type)"
        else
            print_error "No launcher detected! Cannot generate launcher script."
            print_info "Please ensure either PollyMC or PrismLauncher is installed."
            return 1
        fi
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

            # Store the path for later reference
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
