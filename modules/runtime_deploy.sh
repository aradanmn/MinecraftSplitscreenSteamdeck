#!/bin/bash
# =============================================================================
# RUNTIME DEPLOY MODULE
# =============================================================================
# Puts OUR tree in place under TARGET_DIR: the launcher entry script (stamped
# with build provenance) and the runtime orchestrator modules named by the #49
# manifest.
#
# #91: split out of launcher_setup.sh, which was doing four unrelated jobs. The
# split is by QUESTION: launcher_setup.sh answers "is PolyMC installed and
# configured?", this module answers "is the splitscreen tree deployed?".
#
# RELATIONSHIP TO deploy.sh: they solve the same problem for different inputs
# and are deliberately NOT merged. This module has a three-tier source fallback
# (the installer's temp MODULES_DIR, then a local checkout, then a download
# from MCSS_REPO_RAW_URL) because curl|bash installs have no checkout at all.
# deploy.sh copies from a checkout and only a checkout — a download fallback in
# a dev tool would silently mask the very drift it exists to detect. What they
# DO share is the stamp format, via modules/version_stamp.sh (#89).
#
# Public API:
#   setup_splitscreen_launcher_script() — install minecraftSplitscreen.sh;
#                                       return 1 if the fetch produced no
#                                       usable script
#   install_runtime_modules()        — deploy modules/ from
#                                       runtime_modules.list; return 1 if the
#                                       manifest or any module can't be found
#
# Globals CONSUMED (set elsewhere, read here):
#   TARGET_DIR              — installer entry; deploy root
#   MCSS_REPO_RAW_URL       — installer entry; download base
#   SCRIPT_DIR, MODULES_DIR — installer entry (local-checkout fallbacks)
#   read_runtime_manifest() — #89: install-minecraft-splitscreen.sh's canonical
#                              manifest parser, already defined in-process when
#                              sourced from the installer entry (the normal
#                              path); soft-guard-redefined below if absent, so
#                              standalone sourcing (tests) still works
#   mcss_stamp_resolve/mcss_stamp_apply — modules/version_stamp.sh (#89)
#
# Inputs:  MCSS_REPO_RAW_URL downloads, modules/runtime_modules.list (#49).
# Outputs: minecraftSplitscreen.sh + modules/ deployed under $TARGET_DIR;
#          version-stamp substitution on the deployed launcher.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-07-30  #91: split out of launcher_setup.sh
# =============================================================================

# setup_splitscreen_launcher_script: Install minecraftSplitscreen.sh into
# TARGET_DIR. Prefers a local repository copy, falls back to a
# MCSS_REPO_RAW_URL download, then stamps build provenance (version/commit/
# date) into the deployed copy.
# Inputs:
#   Globals: TARGET_DIR, SCRIPT_DIR, MCSS_REPO_RAW_URL (read)
# Outputs:
#   side effects — $TARGET_DIR/minecraftSplitscreen.sh written + executable
#   return — 1 if the fetch produced no usable script (missing/empty/no
#            shebang); the launcher stamp failure itself is non-fatal
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
    # #89: format owned by modules/version_stamp.sh — deploy.sh applies the same
    # one. No mark_dirty here: the installer stamps a freshly fetched tree.
    local _ver _commit _date
    # #170: hand over REPO_REF so a curl|bash install (no local checkout) stamps
    # the ref it actually fetched instead of an unrelated repo's HEAD.
    IFS=$'\t' read -r _ver _commit _date \
        < <(mcss_stamp_resolve "${SCRIPT_DIR:-.}" "" "${REPO_REF:-}")
    if mcss_stamp_apply "$launcher_script" "$_ver" "$_commit" "$_date"; then
        print_info "Stamped launcher: version=${_ver} commit=${_commit}"
    else
        print_warning "Could not stamp launcher version (will report as dev/unknown)"
    fi

    print_success "Splitscreen launcher script installed: $launcher_script"
    return 0
}

# #89: read_runtime_manifest is install-minecraft-splitscreen.sh's
# canonical manifest parser. In the normal path this module is SOURCED BY
# that entry script (same process), so the function is already defined by
# the time install_runtime_modules() runs below — redefine it here ONLY if
# absent (cross-module soft guard, STYLE-GUIDE §7.6) so
# tests/test_installer.sh's standalone `source modules/launcher_setup.sh`
# (T7.7) keeps passing without depending on the installer entry at all.
declare -f read_runtime_manifest >/dev/null 2>&1 || read_runtime_manifest() {
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null
}

# install_runtime_modules: Deploy the runtime orchestrator modules to
# TARGET_DIR/modules/. Sourced by minecraftSplitscreen.sh at launch time, not
# at install time. #49: the module list is read from the ONE manifest,
# runtime_modules.list — preferred from MODULES_DIR, then the local repo
# checkout, then a GitHub download.
# Inputs:
#   Globals: TARGET_DIR, MCSS_REPO_RAW_URL, MODULES_DIR, SCRIPT_DIR (read)
# Outputs:
#   side effects — modules + the manifest copied under $TARGET_DIR/modules/
#   return — 1 if the manifest can't be found/is empty, or any listed
#            module fails to download (deploying a partial set is refused)
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
    mapfile -t runtime_mods < <(read_runtime_manifest "$manifest_src")
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
