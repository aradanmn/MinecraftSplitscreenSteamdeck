#!/bin/bash
# =============================================================================
# LAUNCHER SETUP MODULE
# =============================================================================
# PolyMC setup functions
# PolyMC is used as the primary launcher for splitscreen gameplay

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

# download_prism_launcher: Download the latest PolyMC AppImage
# We download it to the target directory for splitscreen launcher usage
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

# configure_polymc_defaults: Write a baseline PolyMC config to avoid first-run setup prompts.
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

# setup_splitscreen_launcher_script: Install minecraftSplitscreen.sh into TARGET_DIR
# Prefer local repository copy when available, fall back to GitHub download.
setup_splitscreen_launcher_script() {
    print_progress "Installing splitscreen launcher script..."

    local launcher_script="$TARGET_DIR/minecraftSplitscreen.sh"
    local local_script="${SCRIPT_DIR:-}/minecraftSplitscreen.sh"
    local remote_script="${MCSS_REPO_RAW_URL}/minecraftSplitscreen.sh"

    if [[ -f "$local_script" ]]; then
        cp "$local_script" "$launcher_script"
    else
        # Fix #51 (D14): fetch_url replaces the curl/wget/neither chain.
        # It prints its own error when no downloader is installed; any
        # fetch failure falls through to the -s/shebang check below,
        # which reports the detailed fatal error.
        fetch_url "$remote_script" "$launcher_script" || true
    fi

    # The launcher IS the product — fail loudly if the fetch didn't produce a real script
    # (e.g. a 404 from a ref that doesn't have it), instead of chmod-ing an empty file and
    # letting the installer report success downstream.
    if [[ ! -s "$launcher_script" ]] || ! head -n1 "$launcher_script" | grep -q '^#!'; then
        print_error "Launcher fetch failed: $launcher_script is missing/empty or not a script"
        print_info "  (tried: ${local_script:-<none>} then ${remote_script})"
        rm -f "$launcher_script" 2>/dev/null || true
        return 1
    fi

    chmod +x "$launcher_script"

    # Stamp build provenance into the deployed copy (version / commit / date).
    # The launcher carries __MCSS_*__ placeholders; replace them here. A failure
    # is non-fatal — the launcher falls back to dev/unknown if left un-stamped.
    local _ver _commit _date
    _ver=$(cat "${SCRIPT_DIR:-}/VERSION" 2>/dev/null || echo "dev")
    _commit=$(git -C "${SCRIPT_DIR:-.}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    _date=$(date -Iseconds 2>/dev/null || date 2>/dev/null || echo "unknown")
    sed -i \
        -e "s/__MCSS_VERSION__/${_ver}/" \
        -e "s/__MCSS_COMMIT__/${_commit}/" \
        -e "s|__MCSS_BUILD_DATE__|${_date}|" \
        "$launcher_script" 2>/dev/null \
        && print_info "Stamped launcher: version=${_ver} commit=${_commit}" \
        || print_warning "Could not stamp launcher version (will report as dev/unknown)"

    print_success "Splitscreen launcher script installed: $launcher_script"
    return 0
}

# install_runtime_modules: Deploy the runtime orchestrator modules to TARGET_DIR/modules/
# These modules are sourced by minecraftSplitscreen.sh at launch time (not at install time).
# Prefers files already in MODULES_DIR (put there by the installer's download step),
# falls back to local repo copy, then GitHub download.
install_runtime_modules() {
    print_progress "Installing runtime orchestrator modules..."

    local dest_dir="$TARGET_DIR/modules"
    mkdir -p "$dest_dir"

    local base_url="${MCSS_REPO_RAW_URL}/modules"

    # #49: the module list comes from the ONE manifest (runtime_modules.list) —
    # preferred from MODULES_DIR (the installer entry put it there), then the
    # local repo checkout, then GitHub. Missing/empty is FATAL: silently
    # deploying zero modules would brick the launcher.
    local manifest="runtime_modules.list"
    local manifest_src=""
    if [[ -n "${MODULES_DIR:-}" && -s "$MODULES_DIR/$manifest" ]]; then
        manifest_src="$MODULES_DIR/$manifest"
    elif [[ -n "${SCRIPT_DIR:-}" && -s "$SCRIPT_DIR/modules/$manifest" ]]; then
        manifest_src="$SCRIPT_DIR/modules/$manifest"
    else
        # Fix #51 (D14): fetch_url replaces the curl/wget branches.
        fetch_url "$base_url/$manifest" "$dest_dir/$manifest" \
            2>/dev/null || true
        [[ -s "$dest_dir/$manifest" ]] && manifest_src="$dest_dir/$manifest"
    fi
    if [[ -z "$manifest_src" ]]; then
        print_error "$manifest not found (MODULES_DIR, repo checkout, or download) — cannot install runtime modules"
        return 1
    fi
    local runtime_mods=()
    mapfile -t runtime_mods < <(grep -vE '^[[:space:]]*(#|$)' "$manifest_src")
    if [[ ${#runtime_mods[@]} -eq 0 ]]; then
        print_error "$manifest is empty — refusing to deploy a launcher with no runtime modules"
        return 1
    fi
    # Deploy the manifest itself alongside the modules: the launcher reads it
    # at startup to know what to source.
    if [[ "$manifest_src" != "$dest_dir/$manifest" ]]; then
        cp "$manifest_src" "$dest_dir/$manifest"
    fi

    local failed=0
    for mod in "${runtime_mods[@]}"; do
        local dest="$dest_dir/$mod"
        # 1. Already in the temp modules dir (most common path)
        if [[ -n "${MODULES_DIR:-}" && -f "$MODULES_DIR/$mod" ]]; then
            cp "$MODULES_DIR/$mod" "$dest"
        # 2. Local repo copy next to the installer
        elif [[ -n "${SCRIPT_DIR:-}" && -f "$SCRIPT_DIR/modules/$mod" ]]; then
            cp "$SCRIPT_DIR/modules/$mod" "$dest"
        # 3. Download from GitHub
        # Fix #51 (D14): fetch_url replaces the curl/wget/neither
        # branches (its no-downloader case also lands here as a failure).
        elif ! fetch_url "$base_url/$mod" "$dest" 2>/dev/null; then
            print_error "Failed to download runtime module: $mod"
            (( failed++ )) || true
            continue
        fi
        chmod +x "$dest"
        print_success "Runtime module installed: $dest"
    done

    if (( failed > 0 )); then
        print_error "$failed runtime module(s) could not be installed"
        print_info "The launcher (minecraftSplitscreen.sh) will fail to start without them."
        print_info "Re-run the installer or manually copy modules/ from the repository to:"
        print_info "  $dest_dir"
        return 1
    fi

    print_success "All runtime orchestrator modules installed to $dest_dir"
    return 0
}

# Fix #90: ensure_bwrap_installed deleted — vestigial, zero real callers.
# preflight.sh already hard-requires bwrap (with distro-aware guidance) before
# anything else runs, so by the time any installer code executes bwrap is
# guaranteed present; this was a redundant re-check.
