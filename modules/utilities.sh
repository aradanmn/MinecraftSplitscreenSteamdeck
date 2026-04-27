#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# Progress and status reporting functions and general utilities
# These functions provide consistent, colored output for better user experience

# get_prism_executable: Get the correct path to PolyMC executable
# Handles both AppImage and extracted versions (for FUSE issues)
get_prism_executable() {
    if [[ -x "$TARGET_DIR/squashfs-root/AppRun" ]]; then
        echo "$TARGET_DIR/squashfs-root/AppRun"
    elif [[ -x "$TARGET_DIR/PolyMC.AppImage" ]]; then
        echo "$TARGET_DIR/PolyMC.AppImage"
    elif [[ -x "$TARGET_DIR/PrismLauncher.AppImage" ]]; then
        # Backward compatibility for existing installs that still use the old filename.
        echo "$TARGET_DIR/PrismLauncher.AppImage"
    else
        return 1  # No executable found, return failure instead of exiting
    fi
}

# print_header: Display a section header with visual separation
print_header() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# print_success: Display successful operation with green checkmark
print_success() {
    echo "✅ $1"
}

# print_warning: Display warning message with yellow warning symbol
print_warning() {
    echo "⚠️  $1"
}

# print_error: Display error message with red X symbol (sent to stderr)
print_error() {
    echo "❌ $1" >&2
}

# print_info: Display informational message with blue info symbol
print_info() {
    echo "💡 $1"
}

# print_progress: Display in-progress operation with spinning arrow
print_progress() {
    echo "🔄 $1"
}

# print_debug: Display debug message only when --debug flag is enabled
print_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo "🐛 $1"
    fi
}
