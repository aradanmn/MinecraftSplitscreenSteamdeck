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

# fetch_url: Download a URL with curl, falling back to wget.
# Fix #51 (D14): the one transport helper — the curl-vs-wget dance was
# repeated ~20x with timeouts drifted across 10/12/15s/none.
# Inputs:
#   $1 — url
#   $2 — output path ("-" streams the body to stdout)
#   $3 — timeout in seconds (default 15; 0 = no timeout, for bulk artifacts)
# Outputs:
#   stdout — the body when $2 is "-"
#   return — curl/wget exit status; 127 if neither tool is installed
fetch_url() {
    local url="$1" out="$2" timeout_s="${3:-15}"
    if command -v curl >/dev/null 2>&1; then
        local -a copts=(-fsSL)
        (( timeout_s > 0 )) && copts+=(--max-time "$timeout_s")
        curl "${copts[@]}" -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        local -a wopts=(-q)
        (( timeout_s > 0 )) && wopts+=(--timeout="$timeout_s")
        wget "${wopts[@]}" -O "$out" "$url"
    else
        print_error "fetch_url: neither curl nor wget is installed"
        return 127
    fi
}

# fetch_url_status: Download to a file and echo the HTTP status code.
# For callers that branch on 200/404 rather than exit status. curl-only —
# wget cannot report the status code cleanly.
# Inputs:
#   $1 — url
#   $2 — output path
#   $3 — timeout in seconds (default 15)
# Outputs:
#   stdout — 3-digit HTTP status ("000" on transport failure)
#   return — curl exit status; 127 if curl is missing
fetch_url_status() {
    local url="$1" out="$2" timeout_s="${3:-15}"
    if ! command -v curl >/dev/null 2>&1; then
        print_error "fetch_url_status: curl is required"
        return 127
    fi
    curl -sSL --max-time "$timeout_s" -w '%{http_code}' -o "$out" \
        "$url" 2>/dev/null
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
