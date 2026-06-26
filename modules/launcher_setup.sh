#!/bin/bash
# =============================================================================
# LAUNCHER SETUP MODULE
# =============================================================================
# PolyMC setup functions
# PolyMC is used as the primary launcher for splitscreen gameplay

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
    prism_url=$(curl -s https://api.github.com/repos/PolyMC/PolyMC/releases/latest | \
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
    cat > "$cfg_path" <<EOF
[General]
ApplicationTheme=system
ConfigVersion=1.2
IconTheme=pe_colored
JavaPath=${java_cfg_path}
Language=en_US
LastHostname=${current_hostname}
MaxMemAlloc=4096
MinMemAlloc=512
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
    local remote_script="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/${REPO_REF:-main}/minecraftSplitscreen.sh"

    if [[ -f "$local_script" ]]; then
        cp "$local_script" "$launcher_script"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$remote_script" -o "$launcher_script"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$launcher_script" "$remote_script"
    else
        print_error "Neither curl nor wget is available to fetch minecraftSplitscreen.sh"
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

# install_runtime_modules: Deploy the 5 runtime orchestrator modules to TARGET_DIR/modules/
# These modules are sourced by minecraftSplitscreen.sh at launch time (not at install time).
# Prefers files already in MODULES_DIR (put there by the installer's download step),
# falls back to local repo copy, then GitHub download.
install_runtime_modules() {
    print_progress "Installing runtime orchestrator modules..."

    local dest_dir="$TARGET_DIR/modules"
    mkdir -p "$dest_dir"

    local base_url="https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/${REPO_REF:-main}/modules"
    local runtime_mods=(
        "preflight.sh"
        "dock_detection.sh"
        "controller_monitor.sh"
        "kwin_positioner.sh"
        "window_manager.sh"
        "instance_lifecycle.sh"
        "watchdog.sh"
        "orchestrator.sh"
        "dex.sh"
    )

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
        elif command -v curl >/dev/null 2>&1; then
            if ! curl -fsSL "$base_url/$mod" -o "$dest" 2>/dev/null; then
                print_error "Failed to download runtime module: $mod"
                (( failed++ )) || true
                continue
            fi
        elif command -v wget >/dev/null 2>&1; then
            if ! wget -qO "$dest" "$base_url/$mod" 2>/dev/null; then
                print_error "Failed to download runtime module: $mod"
                (( failed++ )) || true
                continue
            fi
        else
            print_error "Cannot deploy $mod: no curl/wget and not in local modules dir"
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

# ensure_bwrap_installed: Verify bubblewrap is available; attempt pacman install if not.
# bwrap is required by the launcher to sandbox each Minecraft instance.
ensure_bwrap_installed() {
    if command -v bwrap >/dev/null 2>&1; then
        print_success "bwrap (bubblewrap) is available: $(command -v bwrap)"
        return 0
    fi

    print_warning "bwrap (bubblewrap) not found — required for controller sandboxing"
    print_info "Attempting to install via pacman..."

    if command -v pacman >/dev/null 2>&1; then
        if sudo pacman -S --noconfirm bubblewrap 2>/dev/null; then
            print_success "bubblewrap installed successfully"
            return 0
        else
            print_error "pacman install failed (read-only filesystem on SteamOS?)"
        fi
    fi

    print_error "Could not install bwrap automatically."
    print_info "On SteamOS: sudo steamos-devmode enable && sudo pacman -S bubblewrap"
    print_info "On Arch:    sudo pacman -S bubblewrap"
    print_info "The launcher will not work without bwrap. Install it before running."
    return 1
}
