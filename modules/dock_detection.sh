#!/bin/bash
set -euo pipefail

# =============================================================================
# DOCK DETECTION MODULE
# =============================================================================
# Detects whether the Steam Deck is in handheld mode (built-in screen only)
# or docked mode (external display active).
#
# Public API:
#   get_display_mode()       — stdout: "handheld" or "docked"
#   is_handheld()            — exit 0 if handheld, 1 if docked
#   is_docked()              — exit 0 if docked, 1 if handheld
#   watch_display_mode()     — blocks; writes DISPLAY_MODE_CHANGE to FIFO
#
# Globals PROVIDED: DOCK_DETECTION_DEFAULT_DRM_PATH,
#   DOCK_DETECTION_POLL_INTERVAL_S — readonly module constants.
# Globals CONSUMED: SPLITSCREEN_FIFO (from runtime_context.sh's
#   mcss_resolve_paths); SPLITSCREEN_MODE (override, see below); uses
#   runtime_context's mcss_query_displays for the display-query fallback.
#
# Inputs:  /sys/class/drm sysfs, display-query CLI tools (wlr-randr,
#          kscreen-doctor) via mcss_query_displays.
# Outputs: "handheld"/"docked" on stdout, DISPLAY_MODE_CHANGE to
#          $SPLITSCREEN_FIFO, stderr `[dock_detection]` prefix.
#
# Environment overrides:
#   SPLITSCREEN_MODE         — "handheld" or "docked" (skips detection)
#   DOCK_DETECTION_DRM_PATH  — override /sys/class/drm path (for testing)
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.2 2026-07-15  Fix #51 (D17): mcss_query_displays shared display-query
#                    parser (H14)
#   v1.1 2026-07-01  v1.1 batch: FIFO broken-pipe tolerance, watchdog trap,
#                    dock awk field fix
#   v1.0 2026-06-13  Initial extraction: DRM sysfs detection module
# =============================================================================

# #51/D17: the display-query fallback rides runtime_context's
# mcss_query_displays. Sourcing it here is idempotent (process-local
# sentinels) and makes standalone sourcing (unit tests) behave like the
# launcher prologue, which sources it first.
source "$(dirname "${BASH_SOURCE[0]}")/runtime_context.sh"

# --- Module-level constants ---
readonly DOCK_DETECTION_DEFAULT_DRM_PATH="/sys/class/drm"
readonly DOCK_DETECTION_POLL_INTERVAL_S=3

# --- Internal functions ---

# _detect_via_drm: Scan DRM sysfs connectors for external displays.
# Inputs:
#   Globals: DOCK_DETECTION_DRM_PATH (override, read), else
#     DOCK_DETECTION_DEFAULT_DRM_PATH
# Outputs:
#   stdout — "docked" if any non-eDP connector is connected, else "handheld"
#   return — 1 if the DRM path doesn't exist
_detect_via_drm() {
    local drm_path="${DOCK_DETECTION_DRM_PATH:-$DOCK_DETECTION_DEFAULT_DRM_PATH}"

    echo "[dock_detection] Checking DRM sysfs connectors..." >&2

    if [[ ! -d "$drm_path" ]]; then
        echo "[dock_detection] DRM path $drm_path not found" >&2
        return 1
    fi

    local dir
    for dir in "$drm_path"/card*-*/; do
        [[ -d "$dir" ]] || continue

        local status_file="${dir}status"
        if [[ ! -f "$status_file" ]]; then
            continue
        fi

        local status
        status=$(cat "$status_file" 2>/dev/null || true)
        status="${status//[$'\n\r']/}"

        if [[ "$status" != "connected" ]]; then
            continue
        fi

        # Extract the connector name from the directory path
        local dir_basename
        dir_basename=$(basename "$dir")

        # eDP = embedded DisplayPort (internal panel). Anything else = external.
        # Connector name may be eDP-1, card0-eDP-1, etc. — check if it contains "eDP".
        if [[ "$dir_basename" != *eDP* ]]; then
            echo "[dock_detection] Found connected non-eDP connector: $dir_basename → docked" >&2
            echo "docked"
            return 0
        fi

        echo "[dock_detection] Found connected eDP connector: $dir_basename (internal panel)" >&2
    done

    echo "[dock_detection] No connected non-eDP connectors found → handheld" >&2
    echo "handheld"
    return 0
}

# _detect_via_display_query: docked iff any ENABLED non-eDP output exists.
# Fix #51 (D17): the wlr-randr and kscreen-doctor parsers that lived here as
# two near-copies now ride runtime_context's mcss_query_displays (which also
# owns the kscreen-doctor KDE-session gate + timeout — this fallback used to
# call it bare and could hang a Game Mode launch the same way #78's probe
# cascade did). Bonus fix: the old wlr-randr copy matched "(current)" on
# per-mode lines, which never name a connector — the INTERNAL panel's own
# mode line could therefore read as docked; normalized per-output records
# make the eDP filter structural.
# Outputs:
#   stdout — "docked"/"handheld"
#   return — 1 if no display-query tool answered
_detect_via_display_query() {
    echo "[dock_detection] Trying display-query fallback (wlr-randr/kscreen-doctor)..." >&2

    local name enabled res saw_any=0
    while read -r name enabled res; do
        [[ -n "$name" ]] || continue
        saw_any=1
        [[ "$name" == *eDP* ]] && continue
        if [[ "$enabled" == "enabled" ]]; then
            echo "[dock_detection] Found active non-eDP output: $name (${res}) → docked" >&2
            echo "docked"
            return 0
        fi
    done < <(mcss_query_displays wlr-randr kscreen-doctor)

    if (( saw_any )); then
        echo "[dock_detection] No active non-eDP outputs → handheld" >&2
        echo "handheld"
        return 0
    fi
    echo "[dock_detection] display-query tools unavailable or silent" >&2
    return 1
}

# --- Public API ---

# get_display_mode: Checks SPLITSCREEN_MODE override first, then DRM sysfs,
# then the display-query fallback.
# Inputs: Globals: SPLITSCREEN_MODE (override, read)
# Outputs:
#   stdout — "handheld" or "docked"
#   return — always 0 (falls back to "handheld" if all methods fail); 1 only
#     if SPLITSCREEN_MODE is set to an invalid value
get_display_mode() {
    # Environment variable override
    if [[ -n "${SPLITSCREEN_MODE:-}" ]]; then
        local mode="${SPLITSCREEN_MODE}"
        if [[ "$mode" != "handheld" && "$mode" != "docked" ]]; then
            echo "[dock_detection] ERROR: SPLITSCREEN_MODE=\"$mode\" is invalid. Must be 'handheld' or 'docked'." >&2
            return 1
        fi
        echo "[dock_detection] Using SPLITSCREEN_MODE override: $mode" >&2
        echo "$mode"
        return 0
    fi

    # Method 1: DRM sysfs scan (preferred)
    local result
    if result=$(_detect_via_drm); then
        echo "$result"
        return 0
    fi

    # Method 2: normalized display query (wlr-randr, then kscreen-doctor —
    # same tool order the old per-tool fallbacks tried). Fix #51 (D17).
    if result=$(_detect_via_display_query); then
        echo "$result"
        return 0
    fi

    # All methods failed — default to handheld
    echo "[dock_detection] All detection methods failed, defaulting to handheld" >&2
    echo "handheld"
    return 0
}

# is_handheld: Return exit code 0 if handheld, 1 if docked.
is_handheld() {
    local mode
    mode=$(get_display_mode)
    [[ "$mode" == "handheld" ]]
}

# is_docked: Return exit code 0 if docked, 1 if handheld.
is_docked() {
    local mode
    mode=$(get_display_mode)
    [[ "$mode" == "docked" ]]
}

# watch_display_mode: Watch for display mode changes. Blocks indefinitely.
# Uses inotifywait on the DRM path if available; otherwise polls.
# Intended to be run as a background process by the orchestrator.
# Inputs:
#   Globals: DOCK_DETECTION_DRM_PATH (override), SPLITSCREEN_FIFO (read)
# Outputs:
#   return — 1 if SPLITSCREEN_FIFO is not set (never returns otherwise)
#   side effects — DISPLAY_MODE_CHANGE <mode> to $SPLITSCREEN_FIFO on each
#     detected change
watch_display_mode() {
    local drm_path="${DOCK_DETECTION_DRM_PATH:-$DOCK_DETECTION_DEFAULT_DRM_PATH}"
    local fifo="${SPLITSCREEN_FIFO:-}"

    if [[ -z "$fifo" ]]; then
        echo "[dock_detection] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    local current_mode
    current_mode=$(get_display_mode)

    if command -v inotifywait >/dev/null 2>&1 && [[ -d "$drm_path" ]]; then
        echo "[dock_detection] Using inotifywait on $drm_path for display change detection" >&2
        # N14: `--include 'status'` filtered events to ONLY the per-connector `status`
        # file, which misses hotplug entirely for a connector whose SYSFS DIRECTORY
        # itself is created/removed (e.g. a dock/MST-created DRM connector node) — a
        # directory create/delete event's filename is the connector name (e.g.
        # "card1-DP-4"), which never matches an `--include 'status'` regex, so a brand
        # new connector was silently invisible to this watch. Watch the PARENT broadly
        # (no --include filter, plus moved_to/delete_self) so both a connector
        # appearing/vanishing AND its status flipping trigger a recheck; a false-
        # positive wakeup just costs one cheap get_display_mode() call. The poll
        # fallback below is unchanged as the safety net either way.
        # inotifywait exits with 0 when an event is received; the outer `while` loop
        # re-invokes it fresh each time, so it re-scans the current tree on every pass.
        while inotifywait -q -e modify,create,delete,moved_to,delete_self -r "$drm_path" 2>/dev/null; do
            # Debounce: brief sleep then check
            sleep 0.5
            local new_mode
            new_mode=$(get_display_mode)
            if [[ "$new_mode" != "$current_mode" ]]; then
                echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
                echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
                current_mode="$new_mode"
            fi
        done
    else
        echo "[dock_detection] inotifywait not available, polling every ${DOCK_DETECTION_POLL_INTERVAL_S}s" >&2
        while true; do
            sleep "$DOCK_DETECTION_POLL_INTERVAL_S"
            local new_mode
            new_mode=$(get_display_mode)
            if [[ "$new_mode" != "$current_mode" ]]; then
                echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
                echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
                current_mode="$new_mode"
            fi
        done
    fi
}
