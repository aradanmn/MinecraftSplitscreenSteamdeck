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
#                                           [--help]
#   --yes         Skip confirmation prompts
#   --dry-run     Show what would be removed; deletes nothing
#   --keep-data   Keep worlds/saves/accounts; remove launcher + shortcuts only
#   --help        Show usage and exit
#
# Env CONSUMED: TARGET_DIR (default $HOME/.local/share/PolyMC), PRISM_DIR
#               (default $HOME/.local/share/PrismLauncher) — overrides for a
#               relocated install.
# Inputs:  the install tree under TARGET_DIR/PRISM_DIR.
# Outputs: removes files/dirs (FULL_TARGETS or KEEP_DATA_TARGETS), print_*
#          stderr-free UX (all print_* helpers write to stdout).
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.2 2026-07-10  D16/#45 PR3: deletion list derives from resolved roots
#   v1.1 2026-07-07  #41: clean legacy JAVA_*_HOME litter from older installs
#   v1.0 2026-04-24  Initial standalone uninstaller (full + --keep-data modes)
# =============================================================================

set -euo pipefail

DRY_RUN=false
ASSUME_YES=false
KEEP_DATA=false
MODE_EXPLICIT=false

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
  --help        Show this help message

Environment:
  TARGET_DIR    Install root to remove (default: \$HOME/.local/share/PolyMC)
  PRISM_DIR     PrismLauncher root (default: \$HOME/.local/share/PrismLauncher)
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
fi
echo ""

if [[ "$KEEP_DATA" == true ]]; then
    print_info "Data under $TARGET_DIR/instances and $TARGET_DIR/accounts.json will be preserved."
else
    print_warning "This can remove your local instances, mods, and worlds in PolyMC/PrismLauncher."
fi
print_info "Steam library shortcuts are not edited automatically."
print_info "If needed, remove the Steam shortcut manually from Steam."
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
