#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# Progress and status reporting functions and general utilities
# These functions provide consistent, colored output for better user experience

# get_prism_executable: Get the correct path to PrismLauncher executable
# Handles both AppImage and extracted versions (for FUSE issues)
get_prism_executable() {
    if [[ -x "$PRISMLAUNCHER_DIR/squashfs-root/AppRun" ]]; then
        echo "$PRISMLAUNCHER_DIR/squashfs-root/AppRun"
    elif [[ -x "$PRISMLAUNCHER_DIR/PrismLauncher.AppImage" ]]; then
        echo "$PRISMLAUNCHER_DIR/PrismLauncher.AppImage"
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

# =============================================================================
# ACCOUNT MANAGEMENT FUNCTIONS
# =============================================================================

# merge_accounts_json: Merge splitscreen accounts into existing accounts.json
# This preserves any existing accounts (Microsoft, etc.) and appends P1-P4 accounts
# Arguments: $1 = source accounts.json (splitscreen accounts)
#            $2 = destination accounts.json (may contain existing accounts)
# Returns: 0 on success, 1 on failure
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
        # Fallback: just overwrite if we can't merge properly
        # This is not ideal but better than failing completely
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
    # This ensures we don't duplicate P1-P4 if they already exist
    if jq -s '
        # Get the splitscreen player names to filter out duplicates
        (.[0].accounts | map(.profile.name)) as $splitscreen_names |
        # Start with existing accounts, removing any that match splitscreen names
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
