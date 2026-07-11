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
# What counts as "the runtime tree" is defined once for everyone (#49):
# the entry script is minecraftSplitscreen.sh and the module list is
# modules/runtime_modules.list — the same manifest the launcher, the installer
# entry, and launcher_setup.sh read. The manifest deploys with the tree.
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
MANIFEST_SOURCE="$MODULES_SRC_DIR/runtime_modules.list"

# --- Runtime module manifest (#49: the ONE manifest, shared with the launcher,
# the installer entry, and launcher_setup.sh — no more parsing a bash array
# out of launcher_setup with sed) ---
runtime_module_list() {
    grep -vE '^[[:space:]]*(#|$)' "$MANIFEST_SOURCE" 2>/dev/null
}

mapfile -t RUNTIME_MODS < <(runtime_module_list)
if [[ ${#RUNTIME_MODS[@]} -eq 0 ]]; then
    echo "deploy.sh: could not read the runtime module manifest: $MANIFEST_SOURCE" >&2
    echo "           (missing or empty — refusing to deploy an empty tree)" >&2
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
# The manifest itself deploys too — the launcher reads it at startup.
WORK+=("$MANIFEST_SOURCE|$MODULES_DST_DIR/runtime_modules.list|modules/runtime_modules.list|")
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

changed=0 unchanged=0 launcher_differs=false
for entry in "${WORK[@]}"; do
    IFS='|' read -r src dst label normalize <<<"$entry"
    if [[ ! -f "$src" ]]; then
        echo "deploy.sh: $label missing from checkout ($src)" >&2
        exit 2
    fi
    # The launcher is deployed AFTER this loop (its stamp must reflect the
    # whole tree, so it is refreshed whenever ANY file changes) — here it only
    # contributes to the changed/unchanged accounting.
    if [[ "$src" == "$LAUNCHER_SRC" ]]; then
        if files_differ "$src" "$dst" "$normalize"; then
            launcher_differs=true
        fi
        continue
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

# Deploy + stamp the launcher whenever anything in the tree changed — not just
# when the launcher itself did. The stamp describes the deployed TREE; found
# on-Deck: a module-only redeploy left the launcher carrying the previous
# deploy's commit/date while this script claimed the new stamp. Re-copying from
# the checkout restores the placeholders so the sed always takes effect.
# Stamped exactly like the installer (launcher_setup.sh), plus a +dirty marker
# so a test log can never claim a clean commit it didn't run.
if [[ "$launcher_differs" == true || $changed -gt 0 || ! -f "$LAUNCHER_DST" ]]; then
    status="updated"; [[ -f "$LAUNCHER_DST" ]] || status="NEW"
    [[ "$launcher_differs" == true || ! -f "$LAUNCHER_DST" ]] || status="re-stamped"
    cp "$LAUNCHER_SRC" "$LAUNCHER_DST"
    chmod +x "$LAUNCHER_DST"
    changed=$((changed + 1))
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
    echo "  → minecraftSplitscreen.sh ($status; stamped version=${_ver} commit=${_commit})"
else
    unchanged=$((unchanged + 1))
fi

echo ""
echo "Deployed to $TARGET_DIR: $changed changed, $unchanged already current."
