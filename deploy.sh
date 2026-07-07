#!/bin/bash
# =============================================================================
# deploy.sh — sync the checkout's runtime tree to the deployed location
# =============================================================================
#
# `git pull` is NOT a deploy: the launcher runs from ~/.local/share/PolyMC/,
# not from this checkout, and testing a stale deployed tree has produced false
# test results twice (issue #54). The installer is the only other deploy path
# and is far too heavy for iterate-test loops. This script closes that gap:
#
#   ./deploy.sh            deploy: copy the entry script + runtime modules from
#                          this checkout into the deployed tree, printing
#                          exactly what changed
#   ./deploy.sh --check    freshness check: diff the deployed tree against the
#                          checkout; exit 0 if fresh, 1 on ANY drift (missing
#                          or differing file). Run before every test phase —
#                          tests/hardware/run_all.sh does this automatically.
#   ./deploy.sh --target D use D instead of ~/.local/share/PolyMC (both modes)
#
# What counts as "the runtime tree" is defined by the installer, not here:
# the entry script is minecraftSplitscreen.sh and the module list is parsed
# at runtime from install_runtime_modules() in modules/launcher_setup.sh —
# deliberately NOT a fourth hand-maintained copy of that manifest (issue #49).
#
# Version stamping: the installer replaces the launcher's __MCSS_VERSION__ /
# __MCSS_COMMIT__ / __MCSS_BUILD_DATE__ placeholders at deploy time. This
# script does the same (marking dirty checkouts as <commit>+dirty), and the
# --check diff normalizes those three lines on both sides so a stamp from an
# older deploy of IDENTICAL code is not reported as drift.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

TARGET_DIR="${MCSS_TARGET_DIR:-$HOME/.local/share/PolyMC}"
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  CHECK_ONLY=true; shift ;;
        --target) TARGET_DIR="${2:?--target requires a directory}"; shift 2 ;;
        -h|--help)
            sed -n '2,31p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "deploy.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

LAUNCHER_SRC="$SCRIPT_DIR/minecraftSplitscreen.sh"
LAUNCHER_DST="$TARGET_DIR/minecraftSplitscreen.sh"
MODULES_SRC_DIR="$SCRIPT_DIR/modules"
MODULES_DST_DIR="$TARGET_DIR/modules"
MANIFEST_SOURCE="$MODULES_SRC_DIR/launcher_setup.sh"

# --- Runtime module manifest, parsed from the installer (single source of truth) ---
# Extracts the quoted filenames inside install_runtime_modules()'s
# `local runtime_mods=( ... )` array.
runtime_module_list() {
    sed -n '/^[[:space:]]*local runtime_mods=($/,/^[[:space:]]*)$/p' "$MANIFEST_SOURCE" \
        | grep -o '"[^"]*\.sh"' | tr -d '"'
}

mapfile -t RUNTIME_MODS < <(runtime_module_list)
if [[ ${#RUNTIME_MODS[@]} -eq 0 ]]; then
    echo "deploy.sh: could not parse runtime_mods from $MANIFEST_SOURCE" >&2
    echo "           (has install_runtime_modules()'s array changed shape?)" >&2
    exit 2
fi

# --- Stamp normalization for the launcher diff ---
# Rewrites the three stamp assignments to their placeholder form so a deployed
# (stamped) launcher and the checkout (placeholder) launcher compare equal when
# the rest of the file is identical. Applied to BOTH sides for symmetry.
normalize_stamps() {
    sed -E \
        -e 's/^(MCSS_VERSION=).*/\1"__MCSS_VERSION__"/' \
        -e 's/^(MCSS_COMMIT=).*/\1"__MCSS_COMMIT__"/' \
        -e 's/^(MCSS_BUILD_DATE=).*/\1"__MCSS_BUILD_DATE__"/' \
        "$1"
}

# files_differ SRC DST [normalize] → 0 if DST is missing or differs from SRC
files_differ() {
    local src="$1" dst="$2" normalize="${3:-}"
    [[ -f "$dst" ]] || return 0
    if [[ "$normalize" == normalize ]]; then
        ! cmp -s <(normalize_stamps "$src") <(normalize_stamps "$dst")
    else
        ! cmp -s "$src" "$dst"
    fi
}

# --- Build the work list: "src|dst|label|normalize" ---
WORK=("$LAUNCHER_SRC|$LAUNCHER_DST|minecraftSplitscreen.sh|normalize")
for mod in "${RUNTIME_MODS[@]}"; do
    WORK+=("$MODULES_SRC_DIR/$mod|$MODULES_DST_DIR/$mod|modules/$mod|")
done

# =============================================================================
# --check mode: report drift, exit nonzero if the deployed tree is stale
# =============================================================================
if [[ "$CHECK_ONLY" == true ]]; then
    drift=0
    for entry in "${WORK[@]}"; do
        IFS='|' read -r src dst label normalize <<<"$entry"
        if [[ ! -f "$src" ]]; then
            echo "  ✗ $label — missing from CHECKOUT ($src)"; drift=$((drift + 1))
        elif [[ ! -f "$dst" ]]; then
            echo "  ✗ $label — not deployed ($dst missing)"; drift=$((drift + 1))
        elif files_differ "$src" "$dst" "$normalize"; then
            echo "  ✗ $label — deployed copy differs from checkout"; drift=$((drift + 1))
        fi
    done
    if [[ $drift -gt 0 ]]; then
        echo ""
        echo "STALE: $drift file(s) drifted — deployed tree ($TARGET_DIR) does not match this checkout."
        echo "Run: $SCRIPT_DIR/deploy.sh    (git pull is not a deploy)"
        exit 1
    fi
    echo "✓ Deployed tree is fresh: $TARGET_DIR matches the checkout (${#WORK[@]} files)."
    exit 0
fi

# =============================================================================
# deploy mode: copy what changed, print it
# =============================================================================
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "deploy.sh: target $TARGET_DIR does not exist — run the installer once first" >&2
    echo "           (deploy.sh only refreshes an existing install; it does not create one)" >&2
    exit 2
fi
mkdir -p "$MODULES_DST_DIR"

changed=0 unchanged=0
for entry in "${WORK[@]}"; do
    IFS='|' read -r src dst label normalize <<<"$entry"
    if [[ ! -f "$src" ]]; then
        echo "deploy.sh: $label missing from checkout ($src)" >&2
        exit 2
    fi
    if files_differ "$src" "$dst" "$normalize"; then
        status="updated"; [[ -f "$dst" ]] || status="NEW"
        cp "$src" "$dst"
        chmod +x "$dst"
        echo "  → $label ($status)"
        changed=$((changed + 1))
    else
        unchanged=$((unchanged + 1))
    fi
done

# Stamp the deployed launcher exactly like the installer does (launcher_setup.sh),
# plus a +dirty marker so a test log can never claim a clean commit it didn't run.
if [[ $changed -gt 0 || ! -f "$LAUNCHER_DST" ]]; then
    _ver=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")
    _commit=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if ! git -C "$SCRIPT_DIR" diff --quiet HEAD -- minecraftSplitscreen.sh modules/ 2>/dev/null; then
        _commit="${_commit}+dirty"
    fi
    _date=$(date -Iseconds 2>/dev/null || date)
    sed -i \
        -e "s/__MCSS_VERSION__/${_ver}/" \
        -e "s/__MCSS_COMMIT__/${_commit}/" \
        -e "s|__MCSS_BUILD_DATE__|${_date}|" \
        "$LAUNCHER_DST"
    echo "  → stamped launcher: version=${_ver} commit=${_commit}"
fi

echo ""
echo "Deployed to $TARGET_DIR: $changed changed, $unchanged already current."
