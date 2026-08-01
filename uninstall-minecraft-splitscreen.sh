#!/bin/bash
# =============================================================================
# Minecraft Splitscreen Steam Deck & Linux Uninstaller
# =============================================================================
# Standalone, curl|bash-able uninstaller — it cannot source runtime_context.sh
# (there may be no checkout at all), so its install-root defaults below are a
# deliberate, hand-kept PAIR with the installer entry's TARGET_DIR and
# runtime_context.sh's launcher-root probe (see the "Install roots" block).
# Removes the launcher tree (or just the launcher + shortcuts in --keep-data
# mode), with an optional dry run and a yes/no confirmation prompt.
#
# Usage: uninstall-minecraft-splitscreen.sh [--yes] [--dry-run] [--keep-data]
#                                           [--purge] [--help]
#   --yes         Skip confirmation prompts
#   --dry-run     Show what would be removed; deletes nothing
#   --keep-data   Keep worlds/saves/accounts; remove launcher + shortcuts only
#   --purge       Leave no trace: everything --keep-data would spare, PLUS the
#                 BYOK key dir, the evsieve build container, and the Steam
#                 shortcut. Mutually exclusive with --keep-data.
#   --help        Show usage and exit
#
# Env CONSUMED: TARGET_DIR (default $HOME/.local/share/PolyMC), PRISM_DIR
#               (default $HOME/.local/share/PrismLauncher) — overrides for a
#               relocated install. MCSS_REPO_RAW_URL — base for fetching
#               remove-from-steam.py when there is no local checkout.
# Inputs:  the install tree under TARGET_DIR/PRISM_DIR.
# Outputs: removes files/dirs (FULL_TARGETS or KEEP_DATA_TARGETS), print_*
#          stderr-free UX (all print_* helpers write to stdout).
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.3 2026-08-01  #122: --purge (BYOK dir, evsieve box, Steam shortcut)
#   v1.2 2026-07-10  D16/#45 PR3: deletion list derives from resolved roots
#   v1.1 2026-07-07  #41: clean legacy JAVA_*_HOME litter from older installs
#   v1.0 2026-04-24  Initial standalone uninstaller (full + --keep-data modes)
# =============================================================================

set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
KEEP_DATA=false
MODE_EXPLICIT=false
PURGE=false

# curl|bash delivers this script on STDIN, where BASH_SOURCE is unset and set -u
# would be fatal — same guard the installer entry uses. Only used to find a
# sibling remove-from-steam.py in a real checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# PAIRED with modules/evsieve_management.sh's EVSIEVE_DISTROBOX_NAME/_IMAGE.
# This script is standalone (it may run with no checkout at all) so it cannot
# source that module; a rename there must be mirrored here.
EVSIEVE_BOX_NAME="${EVSIEVE_DISTROBOX_NAME:-mcss-evsieve-build}"
EVSIEVE_BOX_IMAGE="debian:12"

# --- Install roots (D16/#45 PR 3) --------------------------------------------
# The uninstaller is standalone (curl|bash-able, no checkout) so it cannot
# source runtime_context.sh — these PAIR with the installer entry's TARGET_DIR
# and runtime_context.sh's launcher-root probe. Every deletion below derives
# from them; env-overridable so a relocated install can be uninstalled
# (TARGET_DIR=/path ./uninstall-minecraft-splitscreen.sh).
TARGET_DIR="${TARGET_DIR:-$HOME/.local/share/PolyMC}"
PRISM_DIR="${PRISM_DIR:-$HOME/.local/share/PrismLauncher}"
DESKTOP_BASENAME="MinecraftSplitscreen.desktop"

FULL_TARGETS=(
    "$TARGET_DIR"
    "$PRISM_DIR"
    "$HOME/Desktop/$DESKTOP_BASENAME"
    "$HOME/.local/share/applications/$DESKTOP_BASENAME"
    # Legacy JDK dir from older installers (#41 — current installs keep Java
    # under $TARGET_DIR/java, removed with the tree above)
    "$HOME/.local/jdk"
)

# --purge only. The BYOK CurseForge key (#120) lives outside the install root,
# so a full uninstall leaves it behind — deliberate for a reinstall, wrong for
# "leave no trace". PAIRED with utilities.sh's CURSEFORGE_KEY_FILE default.
PURGE_TARGETS=(
    "$HOME/.config/minecraft-splitscreen"
)

KEEP_DATA_TARGETS=(
    "$TARGET_DIR/PolyMC.AppImage"
    "$TARGET_DIR/minecraftSplitscreen.sh"
    "$TARGET_DIR/live.check"
    "$TARGET_DIR/PolyMC-*.log"
    "$TARGET_DIR/minecraft-splitscreen-icons"
    "$PRISM_DIR/PrismLauncher.AppImage"
    "$PRISM_DIR/minecraftSplitscreen.sh"
    "$HOME/Desktop/$DESKTOP_BASENAME"
    "$HOME/.local/share/applications/$DESKTOP_BASENAME"
)

# print_header: Print a banner-boxed title line ($1).
print_header() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# print_info: Print an info-tagged UX line ($1).
print_info() {
    echo "ℹ️  $1"
}

# print_success: Print a success-tagged UX line ($1).
print_success() {
    echo "✅ $1"
}

# print_warning: Print a warning-tagged UX line ($1).
print_warning() {
    echo "⚠️  $1"
}

# usage: Print the CLI usage/options/env-vars help text to stdout.
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --yes         Skip confirmation prompts
  --dry-run     Show what would be removed (does not delete anything)
  --keep-data   Keep worlds/saves/accounts, remove launcher files and shortcuts
  --purge       Leave no trace. Everything a full uninstall removes, plus:
                  • \$HOME/.config/minecraft-splitscreen (the BYOK API key)
                  • the ${EVSIEVE_BOX_NAME} build container and its image
                  • the Steam shortcut and its library artwork
                Cannot be combined with --keep-data.
  --help        Show this help message

Environment:
  TARGET_DIR    Install root to remove (default: \$HOME/.local/share/PolyMC)
  PRISM_DIR     PrismLauncher root (default: \$HOME/.local/share/PrismLauncher)

Note: --purge edits Steam's shortcuts.vdf, which Steam keeps in memory and
rewrites on exit. Close Steam first or that edit will be silently reverted.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        --keep-data)
            KEEP_DATA=true
            MODE_EXPLICIT=true
            ;;
        --purge)
            PURGE=true
            MODE_EXPLICIT=true
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

# Contradictory intent must be a hard error, never a silent winner: "keep my
# saves" and "leave no trace" cannot both be honoured, and guessing wrong
# destroys worlds. Checked AFTER the whole argv is parsed so flag order cannot
# decide it.
if [[ "$PURGE" == true ]]; then
    if [[ "$KEEP_DATA" == true ]]; then
        echo "--purge and --keep-data are mutually exclusive." >&2
        exit 1
    fi
    KEEP_DATA=false
fi

# If mode was not provided by flags, ask user whether to keep data.
if [[ "$MODE_EXPLICIT" != true ]]; then
    echo "Do you want to keep your Minecraft worlds, saves, and accounts?"
    echo "  y = Keep my data (recommended)"
    echo "  n = Remove everything"
    read -r -p "Keep my data? [Y/n]: " keep_choice
    if [[ "$keep_choice" =~ ^[Nn]$ ]]; then
        KEEP_DATA=false
    else
        KEEP_DATA=true
    fi
fi

print_header "🎮 MINECRAFT SPLITSCREEN UNINSTALLER"
if [[ "$KEEP_DATA" == true ]]; then
    print_info "Keep-data mode: removing launchers and shortcuts, preserving instances/worlds/accounts."
elif [[ "$PURGE" == true ]]; then
    print_info "Purge mode: removing everything, including the API key, build container, and Steam shortcut."
else
    print_info "Full uninstall mode: removing Minecraft Splitscreen launcher data and shortcuts."
fi
echo ""

echo "Targets:"
if [[ "$KEEP_DATA" == true ]]; then
    for path in "${KEEP_DATA_TARGETS[@]}"; do
        echo "  - $path"
    done
else
    for path in "${FULL_TARGETS[@]}"; do
        echo "  - $path"
    done
    if [[ "$PURGE" == true ]]; then
        for path in "${PURGE_TARGETS[@]}"; do
            echo "  - $path"
        done
        echo "  - distrobox container: $EVSIEVE_BOX_NAME (+ its $EVSIEVE_BOX_IMAGE image)"
        echo "  - Steam shortcut \"Minecraft Splitscreen\" + its library artwork"
    fi
fi
echo ""

if [[ "$KEEP_DATA" == true ]]; then
    print_info "Data under $TARGET_DIR/instances and $TARGET_DIR/accounts.json will be preserved."
else
    print_warning "This can remove your local instances, mods, and worlds in PolyMC/PrismLauncher."
fi
if [[ "$PURGE" == true ]]; then
    print_warning "Purge also removes your saved CurseForge API key — you will re-enter it on reinstall."
    print_info "Steam must be CLOSED: it keeps shortcuts.vdf in memory and rewrites it on exit."
else
    print_info "Steam library shortcuts are not edited automatically."
    print_info "If needed, remove the Steam shortcut manually from Steam."
fi
echo ""

if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Are you sure you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "No changes made."
        exit 0
    fi
fi

removed_count=0
missing_count=0

# remove_path: Remove a single target path, or every match of a glob target.
# Inputs: $1 — a path, or a glob pattern (matched via compgen -G)
#         Globals: DRY_RUN (read); removed_count/missing_count (incremented)
# Outputs: side effects — rm -rf per match (real run) or a "[dry-run]" log
#          line (DRY_RUN=true); print_* UX to stdout
remove_path() {
    local path="$1"
    if [[ "$path" == *"*"* ]]; then
        local matches=()
        while IFS= read -r m; do
            matches+=("$m")
        done < <(compgen -G "$path" || true)

        if [[ ${#matches[@]} -eq 0 ]]; then
            print_info "Not found (skipped): $path"
            ((missing_count+=1))
            return
        fi

        for m in "${matches[@]}"; do
            if [[ "$DRY_RUN" == true ]]; then
                print_info "[dry-run] Would remove: $m"
            else
                rm -rf "$m"
                print_success "Removed: $m"
            fi
            ((removed_count+=1))
        done
        return
    fi

    if [[ -e "$path" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[dry-run] Would remove: $path"
        else
            rm -rf "$path"
            print_success "Removed: $path"
        fi
        ((removed_count+=1))
    else
        print_info "Not found (skipped): $path"
        ((missing_count+=1))
    fi
}

if [[ "$KEEP_DATA" == true ]]; then
    for path in "${KEEP_DATA_TARGETS[@]}"; do
        remove_path "$path"
    done
else
    for path in "${FULL_TARGETS[@]}"; do
        remove_path "$path"
    done
fi

# --- --purge extras ----------------------------------------------------------

# remove_evsieve_container: Remove the distrobox this project created to build
# evsieve, and the base image it pulled.
#
# BLAST RADIUS (PRINCIPLES #7, "remove only what you created"): this removes
# OUR named box and nothing else. The issue floated `podman system reset`,
# which wipes every container, image and volume the user owns — on a Deck
# that is probably only ours, but "probably" is not a basis for deleting
# someone's other containers. The shared ~/.local/share/containers store is
# therefore only removed when podman reports nothing left in it, in which case
# it is pure empty overhead.
# Inputs: Globals: DRY_RUN, EVSIEVE_BOX_NAME, EVSIEVE_BOX_IMAGE (read);
#         removed_count (incremented)
# Outputs: side effects — distrobox rm / podman rmi; print_* UX to stdout
#          return — always 0; a missing toolchain is a no-op, not an error
remove_evsieve_container() {
    if ! command -v podman >/dev/null 2>&1; then
        print_info "podman not installed — no build container to remove"
        return 0
    fi

    local box_exists=false
    if command -v distrobox >/dev/null 2>&1 \
        && distrobox list 2>/dev/null \
        | grep -q "[[:space:]]${EVSIEVE_BOX_NAME}[[:space:]]"; then
        box_exists=true
    elif podman container exists "$EVSIEVE_BOX_NAME" 2>/dev/null; then
        box_exists=true
    fi

    if [[ "$box_exists" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[dry-run] Would remove build container: $EVSIEVE_BOX_NAME"
        else
            if command -v distrobox >/dev/null 2>&1; then
                distrobox rm -f "$EVSIEVE_BOX_NAME" >/dev/null 2>&1 || true
            fi
            # distrobox rm can leave the podman container behind if the box was
            # half-created; finish the job either way. Idempotent.
            podman rm -f "$EVSIEVE_BOX_NAME" >/dev/null 2>&1 || true
            print_success "Removed build container: $EVSIEVE_BOX_NAME"
        fi
        ((removed_count+=1))
    else
        print_info "Not found (skipped): build container $EVSIEVE_BOX_NAME"
        ((missing_count+=1))
    fi

    # The base image is only ours to remove if nothing else is using it —
    # podman rmi refuses while a container still references it, which is the
    # safety we want, so let it refuse rather than forcing.
    local image_existed=false
    if podman image exists "$EVSIEVE_BOX_IMAGE" 2>/dev/null; then
        image_existed=true
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[dry-run] Would remove image: $EVSIEVE_BOX_IMAGE"
        elif podman rmi "$EVSIEVE_BOX_IMAGE" >/dev/null 2>&1; then
            print_success "Removed image: $EVSIEVE_BOX_IMAGE"
        else
            print_info "Kept image $EVSIEVE_BOX_IMAGE — another container uses it"
            image_existed=false      # still there; it must count as a leftover
        fi
        ((removed_count+=1))
    fi

    # Only reclaim the shared podman store when it is genuinely empty.
    local left_c left_i
    left_c=$(podman ps -aq 2>/dev/null | wc -l)
    left_i=$(podman images -q 2>/dev/null | wc -l)
    # A dry run has removed NOTHING, so these counts still include our own box
    # and image — and would then report "kept, you have other containers" on a
    # machine where the real run finds nothing left and removes the store.
    # Found on the Deck 2026-08-01: the dry run predicted the OPPOSITE of the
    # real outcome, which is worse than no prediction. Discount our own.
    if [[ "$DRY_RUN" == true ]]; then
        [[ "$box_exists"    == true ]] && left_c=$(( left_c > 0 ? left_c - 1 : 0 ))
        [[ "$image_existed" == true ]] && left_i=$(( left_i > 0 ? left_i - 1 : 0 ))
    fi
    if (( left_c == 0 && left_i == 0 )) \
        && [[ -d "$HOME/.local/share/containers" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[dry-run] Would remove empty podman store: $HOME/.local/share/containers"
        else
            # Mapped-root UIDs inside the store are not removable by a plain
            # rm; `podman unshare` enters the user namespace where they are.
            podman unshare rm -rf "$HOME/.local/share/containers" \
                >/dev/null 2>&1 \
                || rm -rf "$HOME/.local/share/containers" 2>/dev/null \
                || true
            if [[ -d "$HOME/.local/share/containers" ]]; then
                print_warning "Could not fully remove $HOME/.local/share/containers"
            else
                print_success "Removed empty podman store: $HOME/.local/share/containers"
            fi
        fi
        ((removed_count+=1))
    elif (( left_c > 0 || left_i > 0 )); then
        print_info "Kept $HOME/.local/share/containers — you have other podman containers/images"
    fi
    return 0
}

# remove_steam_shortcut: Take our entry back out of Steam's shortcuts.vdf.
#
# Delegates to remove-from-steam.py, the inverse of add-to-steam.py: binary VDF
# surgery belongs in one tested place, not inline here, because shortcuts.vdf
# holds every non-Steam shortcut the user has. FAIL-OPEN (PRINCIPLES #5): if
# the helper cannot be found or fetched, print the manual instruction the old
# uninstaller always printed rather than aborting the whole uninstall.
# Inputs: Globals: DRY_RUN, SCRIPT_DIR, TARGET_DIR (read); removed_count
# Outputs: side effects — runs the helper; print_* UX to stdout; return 0
remove_steam_shortcut() {
    local helper=""
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/remove-from-steam.py" ]]; then
        helper="$SCRIPT_DIR/remove-from-steam.py"
    else
        local raw="${MCSS_REPO_RAW_URL:-https://raw.githubusercontent.com/aradanmn/MinecraftSplitscreenSteamdeck/main}"
        local tmp
        tmp="$(mktemp -t mcss-remove-from-steam.XXXXXX.py)"
        if command -v curl >/dev/null 2>&1 \
            && curl -fsSL --max-time 20 "$raw/remove-from-steam.py" -o "$tmp" \
            && [[ -s "$tmp" ]]; then
            helper="$tmp"
        else
            rm -f "$tmp"
        fi
    fi

    if [[ -z "$helper" ]]; then
        print_warning "Could not obtain remove-from-steam.py — Steam shortcut NOT removed."
        print_info "Remove \"Minecraft Splitscreen\" from your Steam library manually."
        return 0
    fi

    local args=(--target-dir "$TARGET_DIR")
    [[ "$DRY_RUN" == true ]] && args+=(--dry-run)

    if python3 "$helper" "${args[@]}"; then
        ((removed_count+=1))
    else
        # Exit 2 = Steam is running; the helper already explained it.
        print_warning "Steam shortcut was NOT removed (see the message above)."
    fi
    [[ "$helper" == /tmp/* ]] && rm -f "$helper"
    return 0
}

if [[ "$PURGE" == true ]]; then
    echo ""
    print_info "Purge extras:"
    for path in "${PURGE_TARGETS[@]}"; do
        remove_path "$path"
    done
    remove_evsieve_container
    remove_steam_shortcut
fi

# clean_profile_java_exports: Clean stale JAVA_<ver>_HOME exports that older
# installers appended to ~/.profile (#41 — current installs never touch the
# profile). Only lines pointing at directories this project managed are
# removed.
# Inputs: Globals: DRY_RUN (read); removed_count (incremented)
# Outputs: side effects — sed -i deletes matching lines (real run) or a
#          "[dry-run]" count log line; return — always 0 (no profile is a
#          no-op, not an error)
clean_profile_java_exports() {
    local profile="$HOME/.profile"
    [[ -f "$profile" ]] || return 0

    local pattern='^export JAVA_[0-9]+_HOME=.*(/\.local/jdk|/\.local/share/PolyMC/java|'"$HOME"'/java)'
    local matches
    matches=$(grep -cE "$pattern" "$profile" 2>/dev/null || true)
    [[ "${matches:-0}" -gt 0 ]] || return 0

    if [[ "$DRY_RUN" == true ]]; then
        print_info "[dry-run] Would remove $matches JAVA_*_HOME line(s) from $profile"
    else
        sed -i -E "\\#${pattern}#d" "$profile"
        print_success "Removed $matches stale JAVA_*_HOME line(s) from $profile"
    fi
    ((removed_count+=1))
}
clean_profile_java_exports

echo ""
if [[ "$DRY_RUN" == true ]]; then
    print_success "Dry run complete."
else
    print_success "Uninstall complete."
fi
print_info "Removed: $removed_count"
print_info "Skipped (missing): $missing_count"
