#!/bin/bash
# =============================================================================
# UTILITY FUNCTIONS MODULE
# =============================================================================
# Progress and status reporting functions and general utilities
# These functions provide consistent, colored output for better user experience
#
# Network transport (fetch_url/fetch_url_status) and the CurseForge API key
# resolution (BYOK, #120) live here: both are transport-layer / auth-material
# concerns, while the version-match POLICY that consumes the key stays in
# mod_management.sh (ARCHITECTURE.md §2).
#
# Public API:
#   get_prism_executable()        — stdout: PolyMC executable path; return 1
#                                    if none found
#   fetch_url(url, out, [timeout]) — download via curl/wget; "-" streams
#                                    the body to stdout
#   fetch_url_status(url, out, [timeout]) — stdout: HTTP status; return 0
#   resolve_curseforge_api_token() — BYOK, INTERACTIVE; call once up-front in
#                                    the parent shell; exports the resolved
#                                    key; return 1 if none (mods skipped)
#   get_curseforge_api_token()    — pure accessor: stdout key or empty; safe
#                                    inside $(...) (never prompts/networks)
#   print_header/success/warning/error/info/progress/debug(msg) — colored
#                                    UX helpers (error to stderr; debug only
#                                    when DEBUG_MODE=true)
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR          — installer entry (get_prism_executable)
#   CURSEFORGE_API_KEY  — user env, optional (BYOK) — a real key wins
#   CURSEFORGE_KEY_FILE — optional (BYOK), defaults under ~/.config
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

# ---------------------------------------------------------------------------
# CurseForge API key — bring-your-own-key (BYOK), #120.
# The old bundled-token.enc download+decrypt model is retired here: a publicly
# redistributable build can't ship a shared token (#33). Modrinth mods
# (everything installed by default) need no key; only user-added CurseForge
# mods do. `token.enc` is intentionally KEPT in the repo for now so already-
# shipped installs that still fetch it at runtime don't 404 — its deletion is
# gated on #33 (deprecation window).
# ---------------------------------------------------------------------------

# BYOK: default location of the saved user key. The CURSEFORGE_API_KEY env var
# (a real key) always wins over this file. Env-overridable default, set once at
# the owning module per the ARCHITECTURE.md globals ladder (rung 4 — read only
# by utilities.sh).
: "${CURSEFORGE_KEY_FILE:=$HOME/.config/minecraft-splitscreen/curseforge-api-key}"

# _mcss_cf_key_from_env_or_file: NON-interactive key resolution — env var, then
# key file. No prompt, no network. Echoes the key (possibly empty). Always
# returns 0 so `key=$(...)` is safe under `set -e`.
_mcss_cf_key_from_env_or_file() {
    if [[ -n "${CURSEFORGE_API_KEY:-}" ]]; then
        printf '%s' "$CURSEFORGE_API_KEY"
    elif [[ -f "$CURSEFORGE_KEY_FILE" ]]; then
        tr -d '[:space:]' < "$CURSEFORGE_KEY_FILE" 2>/dev/null || true
    fi
    return 0
}

# resolve_curseforge_api_token: up-front, INTERACTIVE key resolution. Call ONCE
# in the parent shell (never inside $(...)) before CurseForge mods are
# processed — e.g. when the user adds a custom CurseForge mod. Order:
# CURSEFORGE_API_KEY env -> key file -> a guarded stdin prompt that skips
# cleanly on piped/EOF stdin (returns non-zero, never hangs — mirrors
# prompt_custom_mods). A real key is saved to CURSEFORGE_KEY_FILE (chmod 600)
# so later mods and future runs don't re-prompt. Exports the result so the
# $()-captured get_curseforge_api_token calls inherit it (parent-shell
# resolution is what makes the export visible to those subshells — the #120
# per-mod-re-prompt fix).
# Outputs: exports _MCSS_CF_API_KEY + _MCSS_CF_KEY_RESOLVED; no stdout.
# return — 0 if a key was resolved, 1 otherwise (CurseForge mods skipped).
resolve_curseforge_api_token() {
    # Idempotent: resolve at most once per install run.
    if [[ -n "${_MCSS_CF_KEY_RESOLVED:-}" ]]; then
        if [[ -n "${_MCSS_CF_API_KEY:-}" ]]; then return 0; else return 1; fi
    fi

    local key
    key=$(_mcss_cf_key_from_env_or_file)

    if [[ -z "$key" ]]; then
        {
            echo ""
            echo "A CurseForge API key is needed to install CurseForge mods."
            echo "(Modrinth mods — everything installed by default — need no key.)"
            echo "Get a free key at https://console.curseforge.com/ -> 'API Keys'."
        } >&2
        # Guarded read from stdin: on a piped/unattended install this hits EOF
        # and returns non-zero, so we skip WITHOUT blocking (the #120
        # unattended-hang fix — the old WIP read /dev/tty and hung).
        if ! read -r -p "CurseForge API key (Enter to skip): " key; then
            key=""
        fi
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        if [[ -n "$key" ]]; then
            if mkdir -p "$(dirname "$CURSEFORGE_KEY_FILE")" 2>/dev/null \
                && printf '%s\n' "$key" > "$CURSEFORGE_KEY_FILE" 2>/dev/null; then
                chmod 600 "$CURSEFORGE_KEY_FILE" 2>/dev/null || true
                print_info "Saved CurseForge key to $CURSEFORGE_KEY_FILE (chmod 600) — delete it to be re-prompted."
            fi
        fi
    fi

    export _MCSS_CF_API_KEY="$key"
    export _MCSS_CF_KEY_RESOLVED=1
    if [[ -z "$key" ]]; then
        print_warning "No CurseForge API key provided — CurseForge mods will be skipped. Modrinth mods are unaffected."
        return 1
    fi
    return 0
}

# get_curseforge_api_token: PURE accessor for the resolved CurseForge key —
# safe inside $(...) because it NEVER prompts and NEVER networks. Returns the
# value resolved up-front by resolve_curseforge_api_token; if that has not run
# (a non-interactive path), falls back to env var / key file only. #120 BYOK:
# replaces the retired token.enc download+decrypt.
# Outputs:
#   stdout — the API key, or empty
#   return — 1 if no key is available, 0 otherwise (callers also treat empty
#            stdout as "skip" via `[[ -z "$api_token" ]]`)
get_curseforge_api_token() {
    if [[ -n "${_MCSS_CF_KEY_RESOLVED:-}" ]]; then
        [[ -n "${_MCSS_CF_API_KEY:-}" ]] \
            && { printf '%s' "$_MCSS_CF_API_KEY"; return 0; }
        return 1
    fi
    local key
    key=$(_mcss_cf_key_from_env_or_file)
    [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
    return 1
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
