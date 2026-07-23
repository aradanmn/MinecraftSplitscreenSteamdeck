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
#   DOCK_DETECTION_POLL_INTERVAL_S, DOCK_DETECTION_DEFAULT_CONFIRM_SAMPLES,
#   DOCK_DETECTION_DEFAULT_CONFIRM_INTERVAL_S — readonly module constants.
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
#   DOCK_DETECTION_CONFIRM_SAMPLES     — #133 debounce depth (default 3)
#   DOCK_DETECTION_CONFIRM_INTERVAL_S  — #133 debounce spacing (default 1)
#
# Version history (one line per version; details live in git; max 6 lines):
#   v1.3 2026-07-23  Fix #133: debounce DISPLAY_MODE_CHANGE — a candidate mode
#                    must hold across N consecutive reads before it is emitted
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
# Guarded (house pattern from runtime_context.sh's _MCSS_CONSTANTS_LOCKED):
# modules are re-sourceable within one process (e.g. a hardware-suite runner
# that sources every stage script into one shell), so an unguarded readonly
# would abort on the second source.
if [[ -z "${_DOCK_DETECTION_CONSTANTS_LOCKED:-}" ]]; then
    readonly DOCK_DETECTION_DEFAULT_DRM_PATH="/sys/class/drm"
    readonly DOCK_DETECTION_POLL_INTERVAL_S=3
    # #133: how many consecutive agreeing reads confirm a mode change, and how
    # far apart they are taken. 3×1s rides out the Deck's known DP status
    # flicker (a blip reverts well inside the window) while a real undock still
    # switches within ~2s. Overridable via DOCK_DETECTION_CONFIRM_* for tests.
    readonly DOCK_DETECTION_DEFAULT_CONFIRM_SAMPLES=3
    readonly DOCK_DETECTION_DEFAULT_CONFIRM_INTERVAL_S=1
    _DOCK_DETECTION_CONSTANTS_LOCKED=1   # process-local — NOT exported
fi

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

    # #70: mcss_query_displays now emits a 4th refresh field; consume it into a
    # throwaway _rate (dock detection only needs name/enabled) so it does not
    # fold into res.
    local name enabled res _rate saw_any=0
    while read -r name enabled res _rate; do
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

# _confirm_display_mode: #133 debounce. Given a candidate mode that a single
# read just reported, re-read the mode until it has been seen
# DOCK_DETECTION_CONFIRM_SAMPLES times in a row (the caller's read is sample 1),
# spacing each extra read DOCK_DETECTION_CONFIRM_INTERVAL_S apart. Bails on the
# FIRST disagreeing read, so a blip costs one interval and not the whole window.
#
# Why: HW-2 (2026-07-22) lost a live docked session to ONE spurious
# `card0-DP-1/status = disconnected` read — the projector was physically
# connected, and DP-1 read `connected` immediately before and after. Un-
# debounced, that single read emitted DISPLAY_MODE_CHANGE handheld, moved
# Minecraft onto the internal panel, and wedged teardown (force reboot). Steam
# Game Mode rides the Deck's known DP flicker out; so must we.
#
# Internal — not part of the public API.
# Inputs:
#   $1 — candidate mode ("handheld"/"docked") the caller's first read returned
#   Globals: DOCK_DETECTION_CONFIRM_SAMPLES, DOCK_DETECTION_CONFIRM_INTERVAL_S
#     (overrides, read)
# Outputs:
#   return — 0 if the candidate held across every sample, 1 if it reverted
#   stderr — one `[dock_detection]` line when a candidate is rejected
_confirm_display_mode() {
    local candidate="$1"
    local samples="${DOCK_DETECTION_CONFIRM_SAMPLES:-$DOCK_DETECTION_DEFAULT_CONFIRM_SAMPLES}"
    local interval="${DOCK_DETECTION_CONFIRM_INTERVAL_S:-$DOCK_DETECTION_DEFAULT_CONFIRM_INTERVAL_S}"

    # Clamp bad overrides instead of erroring: this runs inside a watcher that
    # must never die. samples<1 degrades to the pre-#133 emit-on-first-read.
    [[ "$samples" =~ ^[0-9]+$ ]] && (( samples >= 1 )) || samples=1
    [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || interval="$DOCK_DETECTION_DEFAULT_CONFIRM_INTERVAL_S"

    local i mode
    for (( i = 2; i <= samples; i++ )); do
        sleep "$interval"
        mode=$(get_display_mode 2>/dev/null)
        if [[ "$mode" != "$candidate" ]]; then
            echo "[dock_detection] Transient display change IGNORED: \"$candidate\" did not hold (sample $i/$samples read \"$mode\")" >&2
            return 1
        fi
    done

    if (( samples > 1 )); then
        echo "[dock_detection] Display mode \"$candidate\" confirmed across $samples reads" >&2
    fi
    return 0
}

# watch_display_mode: Watch for display mode changes. Blocks indefinitely.
# Uses inotifywait on the DRM path if available; otherwise polls.
# Intended to be run as a background process by the orchestrator.
# #133: both paths route every candidate change through _confirm_display_mode,
# so a transient sysfs reading never reaches the FIFO. Cost: a real dock/undock
# is reported ~(SAMPLES-1)×INTERVAL later (~2s at the defaults).
# Inputs:
#   Globals: DOCK_DETECTION_DRM_PATH (override), SPLITSCREEN_FIFO (read),
#     DOCK_DETECTION_CONFIRM_SAMPLES / _INTERVAL_S (overrides)
# Outputs:
#   return — 1 if SPLITSCREEN_FIFO is not set (never returns otherwise)
#   side effects — DISPLAY_MODE_CHANGE <mode> to $SPLITSCREEN_FIFO on each
#     detected AND confirmed change
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
            # Settle: brief sleep so a burst of connector writes lands before
            # the first read. The #133 confirmation below does the real work.
            #
            # Known gap (pre-existing, widened by #133 from ~0.5s to ~2.5s):
            # inotifywait is re-invoked per iteration, so DRM events that fire
            # while we are settling/confirming are not queued anywhere — they
            # are lost. Self-correcting in every case that ends in a STEADY
            # state, because the confirmation samples read live status rather
            # than replaying events. The residual risk is a change that lands
            # inside the window and then emits no further event: this branch
            # would sit blocked until the next one. Closing it properly means
            # bounding inotifywait (-t) so the loop doubles as a slow poll —
            # out of scope here, tracked separately.
            sleep 0.5
            local new_mode
            new_mode=$(get_display_mode)
            if [[ "$new_mode" != "$current_mode" ]]; then
                # #133: never emit off a single read — a lone spurious sysfs
                # status can otherwise tear a live docked session down.
                if _confirm_display_mode "$new_mode"; then
                    echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
                    echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
                    current_mode="$new_mode"
                fi
            fi
        done
    else
        echo "[dock_detection] inotifywait not available, polling every ${DOCK_DETECTION_POLL_INTERVAL_S}s" >&2
        while true; do
            sleep "$DOCK_DETECTION_POLL_INTERVAL_S"
            local new_mode
            new_mode=$(get_display_mode)
            if [[ "$new_mode" != "$current_mode" ]]; then
                # #133: this is the path that fired on HW-2 — one spurious
                # DP-1 read here moved a live docked session to the internal
                # panel. Confirm the candidate holds before emitting.
                if _confirm_display_mode "$new_mode"; then
                    echo "[dock_detection] Display mode changed: $current_mode → $new_mode" >&2
                    echo "DISPLAY_MODE_CHANGE $new_mode" >> "$fifo" || true  # H6: tolerate broken pipe
                    current_mode="$new_mode"
                fi
            fi
        done
    fi
}
