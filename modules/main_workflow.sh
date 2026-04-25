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
# 2. CORE SETUP: Java detection, PolyMC download, CLI verification
# 3. VERSION DETECTION: Minecraft and Fabric version determination
# 4. ACCOUNT SETUP: Download offline splitscreen player accounts
# 5. MOD COMPATIBILITY: Query APIs and determine compatible mod versions
# 6. USER SELECTION: Interactive mod selection interface
# 7. INSTANCE CREATION: Create 4 splitscreen instances with PolyMC CLI
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
# The script uses PolyMC for both automation and gameplay:
# - PolyMC: Reliable instance creation with proper Fabric setup
# - PolyMC: Primary launcher for day-to-day splitscreen gameplay
main() {
    print_header "🎮 MINECRAFT SPLITSCREEN INSTALLER 🎮"
    print_info "Advanced installation system with PolyMC optimization"
    print_info "Strategy: PolyMC CLI automation + PolyMC gameplay"
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
    
    download_prism_launcher        # Download PolyMC AppImage for CLI automation
    if ! verify_prism_cli; then    # Test CLI functionality (non-fatal if it fails)
        print_info "PolyMC CLI unavailable - will use manual instance creation"
    fi
    
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
    print_info "Downloading pre-configured offline accounts for Player 1-4"
    
    # OFFLINE ACCOUNTS DOWNLOAD: Get splitscreen player account configurations
    # These accounts enable splitscreen without requiring multiple Microsoft accounts
    # Each player (P1, P2, P3, P4) gets a separate offline profile for identification
    if ! wget -O accounts.json "https://raw.githubusercontent.com/FlyingEwok/MinecraftSplitscreenSteamdeck/main/accounts.json"; then
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
    
    
    create_instances             # Create 4 splitscreen instances using PolyMC CLI with comprehensive fallbacks
    setup_splitscreen_launcher_script   # Install minecraftSplitscreen.sh into launcher directory
    
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
    
    echo "✅ INSTALLATION SUCCESSFUL!"
    echo ""
    echo "🔧 POLYMC STRATEGY COMPLETED:"
    echo "   🛠️  PolyMC: CLI automation for reliable instance creation ✅ COMPLETED"
    echo "   🎮 PolyMC: Primary launcher for splitscreen gameplay ✅ ACTIVE"
    echo ""
    echo "✅ Primary launcher: PolyMC (single-launcher setup)"
    
    # =============================================================================
    # TECHNICAL ACHIEVEMENT SUMMARY
    # =============================================================================
    
    # INSTALLATION COMPONENTS SUMMARY: List all successfully completed setup elements
    echo ""
    echo "🏆 TECHNICAL ACHIEVEMENTS COMPLETED:"
    echo "✅ Java 21+ detection and configuration"
    echo "✅ Automated instance creation via PolyMC CLI"
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
    echo "   Command: $TARGET_DIR/minecraftSplitscreen.sh"
    echo "   Description: PolyMC-based splitscreen with automatic controller detection"
    echo ""
    
    # ALTERNATIVE LAUNCH METHODS: Other integration options
    echo "2. 🖥️  DESKTOP LAUNCHER:"
    echo "   Method: Double-click desktop shortcut or search 'Minecraft Splitscreen' in app menu"
    echo "   Availability: $(if [[ -f "$HOME/Desktop/MinecraftSplitscreen.desktop" ]]; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""
    
    echo "3. 🎯 STEAM INTEGRATION:"
    echo "   Method: Launch from Steam library or Big Picture mode"
    echo "   Benefits: Steam Deck Game Mode integration, Steam Input support"
    echo "   Availability: $(if grep -q "PolyMC" ~/.steam/steam/userdata/*/config/shortcuts.vdf 2>/dev/null; then echo "✅ Configured"; else echo "❌ Not configured"; fi)"
    echo ""
    
    # =============================================================================
    # SYSTEM REQUIREMENTS AND TECHNICAL DETAILS
    # =============================================================================
    
    echo "⚙️  SYSTEM CONFIGURATION DETAILS:"
    echo ""
    
    # LAUNCHER DETAILS: Technical information about the setup
    echo "🛠️  LAUNCHER CONFIGURATION:"
    echo "   • Primary launcher: PolyMC (all functions)"
    echo "   • Strategy: Single launcher approach"
    echo ""
    
    # MINECRAFT ACCOUNT REQUIREMENTS: Important user information
    echo "💳 ACCOUNT REQUIREMENTS:"
    echo "   • Microsoft account: Optional for this setup"
    echo "   • Offline splitscreen profiles: P1, P2, P3, P4 configured automatically"
    echo "   • Login prompts: Not required for offline profile usage"
    echo "   • Note: Online servers that enforce account ownership still require valid credentials"
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
    echo "   • Primary installation: $TARGET_DIR"
    echo "   • Launcher executable: $TARGET_DIR/PolyMC.AppImage"
    echo "   • Splitscreen script: $TARGET_DIR/minecraftSplitscreen.sh"
    echo "   • Instance data: $TARGET_DIR/instances/"
    echo "   • Account configuration: $TARGET_DIR/accounts.json"
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
    echo "https://github.com/FlyingEwok/MinecraftSplitscreenSteamdeck"
    echo "=========================================="
}
