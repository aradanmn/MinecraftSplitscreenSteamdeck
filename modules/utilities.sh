#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# Progress and status reporting functions and general utilities
# These functions provide consistent, colored output for better user experience
#
# Network transport (fetch_url/fetch_url_status) and — per Fix #47 — the
# CurseForge API token fetch+decrypt also live here: both are transport-layer
# concerns (download + auth material), while the version-match POLICY that
# consumes the token stays in mod_management.sh (ARCHITECTURE.md §2).
#
# Public API:
#   get_prism_executable()        — stdout: PolyMC executable path; return 1
#                                    if none found
#   fetch_url(url, out, [timeout]) — download via curl/wget; "-" streams
#                                    the body to stdout
#   fetch_url_status(url, out, [timeout]) — stdout: HTTP status; return 0
#   get_curseforge_api_token()    — stdout: decrypted token or empty
#   print_header/success/warning/error/info/progress/debug(msg) — colored
#                                    UX helpers (error to stderr; debug only
#                                    when DEBUG_MODE=true)
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR — installer entry (get_prism_executable)
#   REPO_REF   — installer entry, optional (get_curseforge_api_token)
#
# Inputs:  network (curl/wget), CurseForge token material.
# Outputs: stdout body for fetch_url("-", ...); colored UX to stderr/stdout
#          per the print_* helper.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.3 2026-07-17  Fix #47/#88: one CurseForge token fetch + policy split
#   v1.2 2026-07-16  Fix #51 D14: restore tolerance — a slow call must not
#                    kill the whole version scan
#   v1.1 2026-07-15  Fix #51 D14: fetch_url/fetch_url_status — one transport
#   v1.0 2025-06-27  Initial extraction from monolith
# =============================================================================

# get_prism_executable: Resolve the PolyMC executable path (AppImage,
# FUSE-extracted squashfs-root, or the legacy PrismLauncher.AppImage name).
# Outputs:
#   stdout — the executable path; return 1 if none of the above exist
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

# get_curseforge_api_token: Download and decrypt the CurseForge API token.
# Fix #47: canonical home. Was copy-pasted at 7 sites across
# mod_management.sh/version_management.sh — same download + openssl AES
# decrypt + hardcoded passphrase + cleanup, each with its own ad hoc
# curl/wget branching and a drifted timeout. All other sites now call this.
# Inputs:
#   Globals: REPO_REF (read, optional) — token.enc branch, default "main"
# Outputs:
#   stdout — the decrypted token, or empty on failure
#   return — 1 if the token file couldn't be fetched at all; 0 otherwise
#            (openssl-missing/decrypt-failure falls through with empty
#            stdout and return 0 — the pre-existing contract every caller
#            already double-checks via `[[ -z "$api_token" ]]`, not just
#            the exit status; preserved as-is, not tightened, per #47/#88's
#            no-behavior-change mandate)
get_curseforge_api_token() {
    local token_url="https://raw.githubusercontent.com/aradanmn/\
MinecraftSplitscreenSteamdeck/${REPO_REF:-main}/token.enc"
    local encrypted_token_file
    encrypted_token_file=$(mktemp)

    if [[ -z "$encrypted_token_file" ]]; then
        echo ""
        return 1
    fi

    # Fix #47: fetch_url replaces the per-site curl/wget branching. Timeout
    # 0 (unbounded) is the most tolerant of the drifted copies — 5 of the 6
    # duplicates had no timeout at all, only one wrapped `timeout 10` — per
    # the #51/D14 tolerance fix, which this must not re-tighten.
    if ! fetch_url "$token_url" "$encrypted_token_file" 0 \
        || [[ ! -s "$encrypted_token_file" ]]; then
        rm -f "$encrypted_token_file"
        echo ""
        return 1
    fi

    local api_token=""
    if command -v openssl >/dev/null 2>&1; then
        api_token=$(openssl enc -d -aes-256-cbc -a -pbkdf2 \
            -in "$encrypted_token_file" \
            -pass pass:"MinecraftSplitscreenSteamDeck2025" 2>/dev/null \
            | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    fi

    rm -f "$encrypted_token_file"
    echo "$api_token"
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
