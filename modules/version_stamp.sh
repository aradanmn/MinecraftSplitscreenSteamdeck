#!/bin/bash
# =============================================================================
# VERSION STAMP MODULE
# =============================================================================
# The ONE place the launcher's build-provenance stamp format is encoded (#89).
#
# minecraftSplitscreen.sh ships with three placeholders — __MCSS_VERSION__,
# __MCSS_COMMIT__, __MCSS_BUILD_DATE__ — which get replaced in the DEPLOYED copy
# so a running launcher can report what it was built from. Two writers do that
# replacement, and one reader has to undo it:
#
#   install path  — launcher_setup.sh setup_splitscreen_launcher_script()
#   dev path      — deploy.sh (adds a `+dirty` marker for a dirty checkout)
#   deploy --check— must NORMALIZE stamps back to placeholders on both sides,
#                   or an older-but-identical deploy reads as drift
#
# Before this module the forward `sed` was verbatim in the two writers and the
# inverse lived only in deploy.sh, so the format was encoded three times: a
# change to it would have silently broken `--check` freshness detection while
# both writers still "worked" (#89, PRINCIPLES #9).
#
# WHY AN INSTALLER MODULE, NOT A RUNTIME ONE: stamping happens at install/deploy
# time only. It is in INSTALLER_MODULE_FILES (so curl|bash mode downloads it)
# and NOT in runtime_modules.list — nothing under the deployed tree sources it.
#
# deploy.sh sources this from the checkout. That is a deliberate, narrow
# exception to its "sources no modules" stance: it is a build-time format
# shared with the installer, not runtime behaviour, and duplicating it is the
# exact bug #89 describes.
#
# Public API:
#   mcss_stamp_apply <file> <version> <commit> <date>  -> 0 on success, 1 on
#                                       sed failure (callers decide severity)
#   mcss_stamp_normalize <file>       — stdout: contents with stamps returned
#                                       to placeholder form
#   mcss_stamp_resolve <checkout_dir> [mark_dirty]
#                                     — stdout: "<version>\t<commit>\t<date>"
#
# Globals CONSUMED: none. Deliberately self-contained — both callers source it
# from different trees, so it must not depend on installer or runtime globals.
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.0 2026-07-29  #89: extracted from launcher_setup.sh + deploy.sh
# =============================================================================

# Re-sourceable: the installer sources modules in dependency order and may be
# re-entered, so this file must not explode on a second source.
if [[ -z "${_MCSS_VERSION_STAMP_LOADED:-}" ]]; then
    _MCSS_VERSION_STAMP_LOADED=1   # process-local — NOT exported
fi

# mcss_stamp_apply: Replace the three placeholders in FILE, in place.
#
# `|` is the delimiter for the date expression because an ISO-8601 date from
# `date -Iseconds` contains `+` and `:` but the timezone offset can also make a
# `/` collision plausible; the other two use `/` as they did before extraction.
# Kept byte-identical to the pre-extraction expressions on purpose.
#
# Inputs:
#   $1 — path to the deployed launcher (modified in place)
#   $2 — version, $3 — commit, $4 — build date
# Outputs:
#   side effects — rewrites $1; writes NOTHING to stdout (callers log their own
#     success/failure wording, which differs between installer and deploy)
#   return — 0 if sed succeeded, 1 otherwise
mcss_stamp_apply() {
    local file="$1" version="$2" commit="$3" date="$4"
    [[ -f "$file" ]] || return 1
    sed -i \
        -e "s/__MCSS_VERSION__/${version}/" \
        -e "s/__MCSS_COMMIT__/${commit}/" \
        -e "s|__MCSS_BUILD_DATE__|${date}|" \
        "$file" 2>/dev/null
}

# mcss_stamp_normalize: Print FILE with the three stamp ASSIGNMENTS rewritten
# back to placeholder form, so a stamped deployed launcher and the placeholder
# checkout copy compare equal when the rest of the file matches.
#
# Note this matches the ASSIGNMENT LINES (`^MCSS_VERSION=...`), not the
# placeholder tokens — by the time it runs, the tokens are gone. That asymmetry
# with mcss_stamp_apply is inherent, and is exactly why both directions belong
# in one file: they are two halves of one format.
#
# Inputs:  $1 — path to a file (not modified)
# Outputs: stdout — normalized contents
mcss_stamp_normalize() {
    sed -E \
        -e 's/^(MCSS_VERSION=).*/\1"__MCSS_VERSION__"/' \
        -e 's/^(MCSS_COMMIT=).*/\1"__MCSS_COMMIT__"/' \
        -e 's/^(MCSS_BUILD_DATE=).*/\1"__MCSS_BUILD_DATE__"/' \
        "$1"
}

# mcss_stamp_resolve: Compute the three stamp values for a checkout.
#
# Every component degrades to a literal rather than failing: an installed tree
# may have no VERSION file, no git, or no `date -Iseconds`, and none of those
# should abort an install (PRINCIPLES #5 — the launcher just reports
# dev/unknown).
#
# The `+dirty` marker is a PARAMETER, not a second copy: deploy.sh wants it (a
# dev tree is routinely dirty), the installer does not (it stamps a clean
# fetched tree). Same divergence-by-parameter pattern as Fix #88's version
# ladders.
#
# Inputs:
#   $1 — checkout dir to read VERSION and git metadata from
#   $2 — "mark_dirty" to append "+dirty" when the launcher or modules/ have
#        uncommitted changes; anything else (or omitted) to skip the check
# Outputs:
#   stdout — "<version>\t<commit>\t<date>", one line, tab-separated
mcss_stamp_resolve() {
    local checkout="${1:-.}" mark_dirty="${2:-}"
    local version commit date
    version=$(cat "$checkout/VERSION" 2>/dev/null || echo "dev")
    commit=$(git -C "$checkout" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if [[ "$mark_dirty" == "mark_dirty" ]] \
        && ! git -C "$checkout" diff --quiet HEAD \
            -- minecraftSplitscreen.sh modules/ 2>/dev/null; then
        commit="${commit}+dirty"
    fi
    date=$(date -Iseconds 2>/dev/null || date 2>/dev/null || echo "unknown")
    printf '%s\t%s\t%s\n' "$version" "$commit" "$date"
}
