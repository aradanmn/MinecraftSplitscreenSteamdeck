#!/bin/bash
# =============================================================================
# TEST WORKDIR LIBRARY
# =============================================================================
# The ONE place the scratch-directory path is encoded (#122).
#
# Test, probe, benchmark and hardware-stage scripts all produce artifacts —
# logs, results files, FIFOs, mangohud captures. They used to drop them loose
# in $HOME, one filename convention per script; a single session left ~90 files
# behind and "get the Deck clean" meant hand-writing a `find ~ | rm`. Every
# such path now resolves through here, so cleanup is one `rm -rf .workdir`.
#
# `.workdir/` sits inside the checkout and is gitignored, which is the point:
# the convention is only a convention if git enforces it. A Deck checkout can
# never accidentally commit its own run output.
#
# WHY tests/lib AND NOT modules/: nothing in the deployed tree writes scratch
# artifacts, and deploy.sh copies only the launcher plus runtime_modules.list —
# tests always run from the checkout. Putting this in modules/ would add a
# runtime dependency that no runtime caller has.
#
# Public API:
#   mcss_workdir [subdir]        — stdout: absolute path (QUERY, creates nothing)
#   mcss_workdir_init [subdir]   — COMMAND: create it; return 0/1
#
# The two are split on purpose (command-query separation): a script that only
# wants to *print* where its results would go must not have the side effect of
# creating the tree.
#
# Globals CONSUMED:
#   MCSS_WORKDIR  — optional absolute override for the scratch root
#   REPO_ROOT     — optional; the checkout root, if the caller already resolved
#                   one. Falls back to this file's own location.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-08-01  #122: extracted; $HOME artifact writers routed here
# =============================================================================

# Re-sourceable: hardware stages source this both standalone and via run_all.sh.
if [[ -z "${_MCSS_WORKDIR_LOADED:-}" ]]; then
    _MCSS_WORKDIR_LOADED=1   # process-local — NOT exported
fi

# _mcss_workdir_root: Resolve the scratch root, without creating it.
#
# Precedence is deliberate. MCSS_WORKDIR wins so a caller can redirect the tree
# (tests do this to avoid touching the real one). Otherwise REPO_ROOT if the
# caller resolved one, and finally this file's own path — tests/lib/workdir.sh
# is two levels below the checkout root. The self-derivation is the reliable
# case: it holds no matter which directory the script was invoked from.
# Outputs: stdout — absolute path to the scratch root (data only)
_mcss_workdir_root() {
    if [[ -n "${MCSS_WORKDIR:-}" ]]; then
        echo "$MCSS_WORKDIR"
        return 0
    fi
    local root="${REPO_ROOT:-}"
    if [[ -z "$root" ]]; then
        root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
    fi
    echo "$root/.workdir"
}

# mcss_workdir: Answer where a script's artifacts belong. Creates nothing.
# Inputs:
#   $1 — optional subdirectory (e.g. "hardware", "uhid-probe"). A caller that
#        omits it gets the root, which is correct for one-off single files.
# Outputs:
#   stdout — absolute path, no trailing slash (data only)
mcss_workdir() {
    local sub="${1:-}"
    local root
    root="$(_mcss_workdir_root)"
    if [[ -n "$sub" ]]; then
        echo "$root/$sub"
    else
        echo "$root"
    fi
}

# mcss_workdir_init: Create the scratch directory so a caller can write into it.
#
# Idempotent — safe to call on every run, and every caller does, because a
# fresh checkout has no .workdir at all.
# Inputs:
#   $1 — optional subdirectory, same meaning as mcss_workdir
# Outputs:
#   return — 0 created or already present, 1 could not create
#   side effects — mkdir -p
mcss_workdir_init() {
    local d
    d="$(mcss_workdir "${1:-}")"
    mkdir -p "$d" 2>/dev/null || {
        echo "[workdir] could not create $d" >&2
        return 1
    }
    return 0
}
