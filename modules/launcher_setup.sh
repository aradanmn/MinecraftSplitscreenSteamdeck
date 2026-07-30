#!/bin/bash
# =============================================================================
# LAUNCHER SETUP MODULE
# =============================================================================
# Gets PolyMC itself installed and configured: downloads the AppImage and
# writes baseline PolyMC defaults so the first-run setup wizard never appears.
#
# #91: this module used to do four unrelated jobs. Deploying OUR tree (the
# launcher script + runtime modules) moved to modules/runtime_deploy.sh; the
# split is by question — this one answers "is PolyMC installed and
# configured?", that one answers "is the splitscreen tree deployed?".
#
# Public API:
#   download_prism_launcher()        — fetch latest PolyMC AppImage; exit 1
#                                       if no download URL is found
#   configure_polymc_defaults()      — write polymc.cfg; return 0
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR              — installer entry
#   MCSS_MAX_MEM_MB, MCSS_MIN_MEM_MB — installer entry (PAIRED copies here
#                              via the := guard below, see Fix #87)
#   MCSS_REPO_RAW_URL       — installer entry; module/launcher download base
#   SCRIPT_DIR, MODULES_DIR — installer entry (local-checkout fallbacks)
#
# Inputs:  GitHub API (PolyMC releases).
# Outputs: PolyMC.AppImage under $TARGET_DIR; polymc.cfg written.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.7 2026-07-30  #91: launcher/module deploy split to runtime_deploy.sh
#   v1.6 2026-07-29  #89: stamping moves to modules/version_stamp.sh
#   v1.5 2026-07-19  #89: manifest parse -> shared read_runtime_manifest
#   v1.4 2026-07-17  Fix #90: delete vestigial Phase-A/JDK/bwrap shims
#   v1.3 2026-07-17  Fix #87: canonical heap-default home + paired guard
#   v1.2 2026-07-15  Fix #51 D14: fetch_url replaces curl/wget branching
#   v1.1 2026-07-10  Fix #45 PR3/#49: MCSS_REPO_RAW_URL + one manifest reader
#   v1.0 2025-06-27  Initial extraction from monolith
# =============================================================================

# --- Module-level constants ---
# Fix #87: canonical home is install-minecraft-splitscreen.sh's constants
# block (near MCSS_MAX_PLAYERS); this module's own := guard exists so
# configure_polymc_defaults() never writes an empty MaxMemAlloc/MinMemAlloc
# if this module is ever sourced without instance_creation.sh (already true
# of tests/test_installer.sh, which sources this file standalone) — the
# previous version had NO fallback here at all and relied entirely on
# instance_creation.sh's source order.
# PAIRED WITH install-minecraft-splitscreen.sh (same values there and in
# modules/instance_creation.sh).
: "${MCSS_MAX_MEM_MB:=3072}"
: "${MCSS_MIN_MEM_MB:=512}"

# download_prism_launcher: Fetch the latest PolyMC AppImage into TARGET_DIR.
# No-op if already present. Queries the GitHub releases API for an x86_64/
# amd64 AppImage asset.
# Inputs:
#   Globals: TARGET_DIR (read)
# Outputs:
#   side effects — $TARGET_DIR/PolyMC.AppImage written + made executable
#   exit 1 — if no matching AppImage URL is found in the release assets
download_prism_launcher() {
    # Skip download if AppImage already exists
    if [[ -f "$TARGET_DIR/PolyMC.AppImage" ]]; then
        print_success "PolyMC AppImage already present"
        return 0
    fi
    
    print_progress "Downloading latest PolyMC AppImage..."
    
    # Query GitHub API to get the latest release download URL
    # We specifically look for AppImage files in the release assets
    local prism_url
    # Fix #51 (D14): fetch_url replaces the bare curl call.
    prism_url=$(fetch_url \
        "https://api.github.com/repos/PolyMC/PolyMC/releases/latest" - | \
        jq -r '.assets[]
            | select(
                (.name | ascii_downcase | endswith("appimage"))
                and (
                    (.name | ascii_downcase | contains("x86_64"))
                    or (.name | ascii_downcase | contains("amd64"))
                )
            )
            | .browser_download_url' | \
        head -n1)
    
    # Validate that we got a valid download URL
    if [[ -z "$prism_url" || "$prism_url" == "null" ]]; then
        print_error "Could not find latest PolyMC AppImage URL."
        print_error "Please check https://github.com/PolyMC/PolyMC/releases manually."
        exit 1
    fi
    
    # Download and make executable
    wget -O "$TARGET_DIR/PolyMC.AppImage" "$prism_url"
    chmod +x "$TARGET_DIR/PolyMC.AppImage"
    print_success "PolyMC AppImage downloaded successfully"
}

# configure_polymc_defaults: Write polymc.cfg so the first-run setup wizard
# (Java/memory Quick Setup) never appears.
# Inputs:
#   Globals: TARGET_DIR, JAVA_PATH, MCSS_MAX_MEM_MB, MCSS_MIN_MEM_MB (read)
# Outputs:
#   side effects — $TARGET_DIR/polymc.cfg written
#   return — 0 (always)
configure_polymc_defaults() {
    print_progress "Configuring PolyMC defaults (Java + memory)..."

    local cfg_path="$TARGET_DIR/polymc.cfg"
    local current_hostname
    if command -v hostname >/dev/null 2>&1; then
        current_hostname=$(hostname)
    elif [[ -n "${HOSTNAME:-}" ]]; then
        current_hostname="$HOSTNAME"
    else
        current_hostname="localhost"
    fi

    local java_cfg_path="${JAVA_PATH:-java}"
    # Heap policy home: modules/instance_creation.sh (MCSS_MAX/MIN_MEM_MB —
    # 4×3072 MiB fits a 16 GB Deck; the 4096 previously hardcoded here was the
    # exact drift the per-instance writer fixed). Sourced alongside this
    # module by the installer entry, so the pair is set before any call.
    cat > "$cfg_path" <<EOF
[General]
ApplicationTheme=system
ConfigVersion=1.2
IconTheme=pe_colored
JavaPath=${java_cfg_path}
Language=en_US
LastHostname=${current_hostname}
MaxMemAlloc=${MCSS_MAX_MEM_MB}
MinMemAlloc=${MCSS_MIN_MEM_MB}
ToolbarsLocked=false
EOF

    print_success "PolyMC defaults written: $cfg_path"
    return 0
}
