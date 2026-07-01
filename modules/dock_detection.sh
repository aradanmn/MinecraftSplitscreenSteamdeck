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
# Environment overrides:
#   SPLITSCREEN_MODE         — "handheld" or "docked" (skips detection)
#   DOCK_DETECTION_DRM_PATH  — override /sys/class/drm path (for testing)
# =============================================================================

# --- Module-level constants ---
readonly DOCK_DETECTION_DEFAULT_DRM_PATH="/sys/class/drm"
readonly DOCK_DETECTION_POLL_INTERVAL_S=3

# --- Internal functions ---

# _detect_via_drm: Scan DRM sysfs connectors for external displays.
# Uses DOCK_DETECTION_DRM_PATH if set, otherwise /sys/class/drm.
# Returns: "docked" if any non-eDP connector is connected, else "handheld".
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

# _detect_via_wlr_randr: Use wlr-randr if available.
# Returns: "docked" if external display is connected, else "handheld".
_detect_via_wlr_randr() {
    echo "[dock_detection] Trying wlr-randr fallback..." >&2

    if ! command -v wlr-randr >/dev/null 2>&1; then
        echo "[dock_detection] wlr-randr not available" >&2
        return 1
    fi

    local output
    output=$(wlr-randr 2>/dev/null || true)

    if [[ -z "$output" ]]; then
        echo "[dock_detection] wlr-randr produced no output" >&2
        return 1
    fi

    # Look for any non-eDP display that is enabled / current
    # wlr-randr output lines look like: "HDMI-A-1 ... 1920x1080 ... (current)"
    local line
    while IFS= read -r line; do
        # Skip eDP lines
        if [[ "$line" == *eDP* ]]; then
            continue
        fi
        # Check for "current" or "enabled" indicator
        if [[ "$line" == *"current"* || "$line" == *"enabled"* ]]; then
            # Extract display name (first word)
            local name
            name=$(echo "$line" | awk '{print $1}')
            echo "[dock_detection] Found active non-eDP output via wlr-randr: $name → docked" >&2
            echo "docked"
            return 0
        fi
    done <<< "$output"

    echo "[dock_detection] No active non-eDP outputs via wlr-randr → handheld" >&2
    echo "handheld"
    return 0
}

# _detect_via_kscreen_doctor: Use kscreen-doctor if available (KDE-specific).
# Returns: "docked" if external display is enabled, else "handheld".
_detect_via_kscreen_doctor() {
    echo "[dock_detection] Trying kscreen-doctor fallback..." >&2

    if ! command -v kscreen-doctor >/dev/null 2>&1; then
        echo "[dock_detection] kscreen-doctor not available" >&2
        return 1
    fi

    local output
    output=$(kscreen-doctor -o 2>/dev/null || true)

    if [[ -z "$output" ]]; then
        echo "[dock_detection] kscreen-doctor produced no output" >&2
        return 1
    fi

    # Parse kscreen-doctor output. Lines look like:
    # Output: 1 eDP-1 enabled ...
    # Output: 2 HDMI-A-1 enabled ...
    local line
    while IFS= read -r line; do
        # Skip eDP lines
        if [[ "$line" == *eDP* ]]; then
            continue
        fi
        if [[ "$line" == *"enabled"* ]]; then
            # H14: "Output: <index> <name> enabled …" → name is field 3, not 2 ($2 is
            # the output index). Only used in the log line, but get it right.
            local name
            name=$(echo "$line" | awk '{print $3}')
            echo "[dock_detection] Found enabled non-eDP output via kscreen-doctor: $name → docked" >&2
            echo "docked"
            return 0
        fi
    done <<< "$output"

    echo "[dock_detection] No enabled non-eDP outputs via kscreen-doctor → handheld" >&2
    echo "handheld"
    return 0
}

# --- Public API ---

# Return "handheld" or "docked" on stdout. Exit code always 0.
# Checks SPLITSCREEN_MODE override first, then DRM sysfs, then fallbacks.
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

    # Method 2: wlr-randr fallback
    if result=$(_detect_via_wlr_randr); then
        echo "$result"
        return 0
    fi

    # Method 3: kscreen-doctor fallback
    if result=$(_detect_via_kscreen_doctor); then
        echo "$result"
        return 0
    fi

    # All methods failed — default to handheld
    echo "[dock_detection] All detection methods failed, defaulting to handheld" >&2
    echo "handheld"
    return 0
}

# Return exit code 0 if handheld, 1 if docked.
is_handheld() {
    local mode
    mode=$(get_display_mode)
    [[ "$mode" == "handheld" ]]
}

# Return exit code 0 if docked, 1 if handheld.
is_docked() {
    local mode
    mode=$(get_display_mode)
    [[ "$mode" == "docked" ]]
}

# Watch for display mode changes. Blocks indefinitely.
# Uses inotifywait on the DRM path if available; otherwise polls.
# On each change, writes a DISPLAY_MODE_CHANGE message to $SPLITSCREEN_FIFO.
# Intended to be run as a background process by the orchestrator.
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
