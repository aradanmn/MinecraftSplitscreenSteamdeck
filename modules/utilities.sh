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
        # -f (fail on HTTP error) only in FILE mode. Stdout consumers judge
        # the body themselves (pre-D14 parity: plain `curl -s`) — with -f, a
        # Modrinth 429 inside a $( ) under the installer's set -e killed the
        # whole version scan (Deck validation 2026-07-15).
        local -a copts=(-sSL)
        [[ "$out" != "-" ]] && copts+=(-f)
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
# ALWAYS returns 0: callers assign the code inside set -e subshells (the
# installer's version scan makes 40+ of these calls; the pre-D14 sites used
# un-timeouted curl that would hang rather than fail, so a --max-time
# expiry must surface as code 000, not a set -e abort — Deck validation
# 2026-07-15 lost the whole scan to one slow Modrinth response).
# Inputs:
#   $1 — url
#   $2 — output path
#   $3 — timeout in seconds (default 15)
# Outputs:
#   stdout — 3-digit HTTP status ("000" on transport failure/missing curl)
#   return — always 0
fetch_url_status() {
    local url="$1" out="$2" timeout_s="${3:-15}"
    if ! command -v curl >/dev/null 2>&1; then
        print_error "fetch_url_status: curl is required"
        echo "000"
        return 0
    fi
    local code
    code=$(curl -sSL --max-time "$timeout_s" -w '%{http_code}' -o "$out" \
        "$url" 2>/dev/null) || code="000"
    echo "${code:-000}"
    return 0
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
