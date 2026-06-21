#!/bin/bash
set -euo pipefail

# =============================================================================
# ORCHESTRATOR MODULE
# =============================================================================
# Main event-loop that reads from SPLITSCREEN_FIFO and dispatches to
# the existing handler modules (controller_monitor, instance_lifecycle,
# window_manager, watchdog, dock_detection).
#
# Architecture:
#   controller_monitor → FIFO → orchestrator → spawn_instance / teardown_instance
#   watchdog           → FIFO → orchestrator → teardown_instance (on SLOT_DIED)
#   dock_detection     → FIFO → orchestrator → switch handheld/docked mode
#
# Public API:
#   handheld_flow()   — Blocks; event loop for handheld (1 slot, Deck controls only)
#   docked_flow()     — Blocks; event loop for docked (up to 4 slots, external controllers)
#   main()            — Detects mode (handheld/docked), runs the correct flow
#   cleanup()         — Stops watchdog, tears down all instances, restores panels
#
# Dependencies:
#   dock_detection.sh, controller_monitor.sh, instance_lifecycle.sh,
#   window_manager.sh, watchdog.sh
# =============================================================================

# ── Module-level constants ───────────────────────────────────────────────────
readonly ORCHESTRATOR_MAX_SLOTS=4
readonly ORCHESTRATOR_SETTLE_DELAY_S=10
readonly ORCHESTRATOR_SPAWN_DELAY_S=3
readonly ORCHESTRATOR_IDLE_TIMEOUT_S=30

# PID tracking for background workers
_WATCHDOG_PID=""
_CONTROLLER_MONITOR_PID=""
_DOCK_MONITOR_PID=""

# =============================================================================
# HELPER: read a single message from the FIFO
# Handles the named pipe in non-blocking mode with a timeout,
# so we can also check PID aliveness in the loop.
# =============================================================================
_read_fifo_msg() {
    local fifo="${SPLITSCREEN_FIFO:-}"
    local timeout_s="${1:-5}"
    [[ -z "$fifo" ]] && return 1
    [[ -p "$fifo" ]] || return 1

    # Use read with timeout so we can check watchdog/monitor health between msgs
    IFS= read -r -t "$timeout_s" msg < "$fifo" 2>/dev/null || return 1
    echo "$msg"
    return 0
}

# =============================================================================
# HELPER: get the current mode from SPLITSCREEN_STATE
# =============================================================================
_get_mode() {
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    jq -r '.mode // "docked"' "$state" 2>/dev/null || echo "docked"
}

# =============================================================================
# HELPER: set the mode in SPLITSCREEN_STATE
# =============================================================================
_set_mode() {
    local mode="$1"
    local state="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
    jq --arg mode "$mode" '.mode = $mode' "$state" > "${state}.tmp" 2>/dev/null && mv "${state}.tmp" "$state" || true
}

# =============================================================================
# HELPER: find the first free slot (1–ORCHESTRATOR_MAX_SLOTS)
# Returns slot number on stdout, empty string if all slots full
# =============================================================================
_find_free_slot() {
    for slot in $(seq 1 "$ORCHESTRATOR_MAX_SLOTS"); do
        if ! slot_is_active "$slot" 2>/dev/null; then
            echo "$slot"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# HELPER: compute and persist the reflowed layout for all active slots
# Writes new kwinrulesrc and calls sync_apply_layout (or the gamescope variant)
# =============================================================================
_reflow_layout() {
    local active
    active=$(get_active_slots)
    [[ -z "$active" ]] && return 0

    # Re-compute KWin rules for the current slot count
    local n_slots
    n_slots=$(echo "$active" | wc -w)
    local ruleW ruleH
    ruleW=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}' | cut -dx -f1) || ruleW=1280
    ruleH=$(xdpyinfo 2>/dev/null | awk '/dimensions/{print $2}' | cut -dx -f2) || ruleH=800

    local slot
    for slot in $active; do
        read _x _y _w _h < <(compute_geometry "$slot" "$n_slots" "$ruleW" "$ruleH")
        # Write splitscreen.properties so the mod renders correctly
        _write_splitscreen_properties "$slot" "$active" 2>/dev/null || true
    done

    # Reflow via the window manager
    if [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]] || [[ -n "${GAMESCOPE_REFRESH_RATE:-}" ]]; then
        if command -v gamescope_windowing_apply_layout >/dev/null 2>&1 || type gamescope_windowing_apply_layout >/dev/null 2>&1; then
            gamescope_windowing_apply_layout "$active" "$ruleW" "$ruleH" 2>/dev/null || true
        else
            sync_apply_layout "$active" "$ruleW" "$ruleH" 2>/dev/null || true
        fi
    else
        sync_apply_layout "$active" "$ruleW" "$ruleH" 2>/dev/null || true
    fi
}

# =============================================================================
# DISPATCHER: handle a single FIFO message
# Returns 0 if the event loop should continue, 1 if it should exit cleanly
# =============================================================================
_handle_msg() {
    local msg="$1"
    [[ -z "$msg" ]] && return 0

    local msg_type="${msg%% *}"
    local msg_arg="${msg#* }"
    [[ "$msg_type" == "$msg_arg" ]] && msg_arg=""

    case "$msg_type" in
        CONTROLLER_ADD)
            local slot
            slot=$(_find_free_slot)
            if [[ -z "$slot" ]]; then
                echo "[orchestrator] All $ORCHESTRATOR_MAX_SLOTS slots full — ignoring controller add" >&2
                return 0
            fi
            echo "[orchestrator] CONTROLLER_ADD → slot $slot (spawning instance)" >&2

            # Extract event_node and js_node from the CONTROLLER_ADD arg if provided
            # Format: "CONTROLLER_ADD /dev/input/eventX /dev/input/jsX"
            local event_node="" js_node=""
            if [[ -n "$msg_arg" ]]; then
                event_node="${msg_arg%% *}"
                js_node="${msg_arg#* }"
                [[ "$event_node" == "$js_node" ]] && js_node=""
            fi

            # ── Controller isolation bridge (feat/controlify-isolation) ───────
            # TODO: Pass mask_controllers=() for all OTHER active slots so
            # each sandbox only exposes one controller. Implementation:
            #   1. Collect all (event_node, js_node) pairs for slots OTHER than this one
            #   2. Pass them as trailing args to spawn_instance
            #   3. In _build_bwrap_command, these become --bind /dev/null masks
            #   4. Set SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1 per-slot
            # Currently passes only this slot's controller (no masking yet).
            # Use a temp file instead of a pipe so bwrap/Java descendants don't
            # inherit the write-end and block the orchestrator's FIFO event loop.
            local _si_log
            _si_log=$(mktemp /tmp/spawn_instance_slot${slot}_XXXXXX.log)
            spawn_instance "$slot" "$event_node" "$js_node" >"$_si_log" 2>&1 || true
            sed 's/^/[orchestrator] /' < "$_si_log" >&2
            rm -f "$_si_log"

            # Give the window time to appear before reflow
            sleep "$ORCHESTRATOR_SPAWN_DELAY_S"
            _reflow_layout
            ;;

        CONTROLLER_REMOVE)
            local slot="$msg_arg"
            if [[ -z "$slot" ]] || ! slot_is_active "$slot" 2>/dev/null; then
                echo "[orchestrator] CONTROLLER_REMOVE: slot $slot not active — ignoring" >&2
                return 0
            fi
            echo "[orchestrator] CONTROLLER_REMOVE → slot $slot (tearing down)" >&2
            teardown_instance "$slot" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
            _reflow_layout
            ;;

        SLOT_DIED)
            local slot="$msg_arg"
            if [[ -z "$slot" ]]; then
                echo "[orchestrator] SLOT_DIED: no slot specified" >&2
                return 0
            fi
            echo "[orchestrator] SLOT_DIED for slot $slot — cleaning up" >&2
            teardown_instance "$slot" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
            _reflow_layout
            ;;

        DISPLAY_MODE_CHANGE)
            local new_mode="$msg_arg"
            echo "[orchestrator] DISPLAY_MODE_CHANGE → $new_mode" >&2
            case "$new_mode" in
                docked)
                    echo "[orchestrator] Switching to docked mode (external display detected)" >&2
                    _set_mode "docked"
                    ;;
                handheld)
                    echo "[orchestrator] Switching to handheld mode (built-in display only)" >&2
                    # ── Docked→Handheld guard ────────────────────────────────
                    # Keep slot 1 alive (it's P1 / Deck controls).
                    # Tear down ALL other active slots.
                    # Reflow to single-player layout if P1 remains.
                    local active_slots
                    active_slots=$(get_active_slots)
                    local _s
                    for _s in $active_slots; do
                        if [[ "$_s" != "1" ]]; then
                            echo "[orchestrator] Teardown slot $_s (docked→handheld transition)" >&2
                            teardown_instance "$_s" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
                        fi
                    done

                    _set_mode "handheld"

                    # If slot 1 survived, reflow to fullscreen single-player layout
                    if slot_is_active 1 2>/dev/null; then
                        echo "[orchestrator] Slot 1 survived — reflowing to single-player layout" >&2
                        _reflow_layout
                    fi
                    # Return 1 so the caller can re-enter handheld_flow
                    return 1
                    ;;
            esac
            ;;

        *)
            echo "[orchestrator] Unknown message: $msg" >&2
            ;;
    esac
    return 0
}

# =============================================================================
# handheld_flow
# Event loop for handheld mode.
# - 1 slot only (slot 1)
# - Only the Deck's built-in controls (no external controllers)
# - Spawns slot 1 on entry, exits when it dies
# - On DISPLAY_MODE_CHANGE docked, switches to docked_flow
# =============================================================================
handheld_flow() {
    set +e
    echo "[orchestrator] Starting handheld flow" >&2
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        echo "[orchestrator] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    # ── Write state: handheld mode
    _set_mode "handheld"

    # ── Start controller monitor (handheld mode — Deck built-ins only)
    # In handheld mode, controllers attached to the Deck itself are the
    # built-in gamepad. The monitor watches for the single Steam virtual gamepad.
    # ── Controller isolation note ──────────────────────────────────────
    # feat/controlify-isolation: In handheld mode, the Deck's built-in
    # controller should NOT be masked in bwrap — it's the ONLY controller
    # available and must reach slot 1 normally. Controller isolation in
    # handheld mode just means ensuring external controllers that happen
    # to be connected don't interfere (they'd be ignored at the SDL level).
    # ────────────────────────────────────────────────────────────────────
    if type start_controller_monitor >/dev/null 2>&1; then
        start_controller_monitor handheld &
        _CONTROLLER_MONITOR_PID=$!
        echo "[orchestrator] Controller monitor PID: $_CONTROLLER_MONITOR_PID" >&2
    fi

    # ── Start dock detection (watch for docked→handheld transitions)
    if type watch_display_mode >/dev/null 2>&1; then
        watch_display_mode &
        _DOCK_MONITOR_PID=$!
        echo "[orchestrator] Dock monitor PID: $_DOCK_MONITOR_PID" >&2
    fi

    # ── Start watchdog (monitor process aliveness)
    if type start_watchdog >/dev/null 2>&1; then
        start_watchdog &
        _WATCHDOG_PID=$!
        echo "[orchestrator] Watchdog PID: $_WATCHDOG_PID" >&2
    fi

    # ── Spawn slot 1 (single player)
    # No controller masking needed — only one instance, one controller.
    echo "[orchestrator] Spawning single instance for handheld mode" >&2
    spawn_instance 1 "" "" 2>&1 | sed 's/^/[orchestrator] /' >&2 || true

    # ── Event loop
    local reflow_needed=false
    while true; do
        # Check if the main instance is still alive
        if ! slot_is_active 1 2>/dev/null; then
            echo "[orchestrator] Slot 1 is no longer active — exiting handheld flow" >&2
            break
        fi

        local msg
        if msg=$(_read_fifo_msg 5); then
            echo "[orchestrator] FIFO message: $msg" >&2
            _handle_msg "$msg" || break
        fi
    done

    cleanup
}

# =============================================================================
# docked_flow
# Event loop for docked mode (external display connected).
# - Up to 4 slots (1 controller → 4 players max)
# - Controllers mapped to individual slots via bwrap isolation
# - Spawns instances as controllers connect, tears down as they disconnect
# - On DISPLAY_MODE_CHANGE handheld (undock), tears down all and exits
# =============================================================================
docked_flow() {
    set +e
    echo "[orchestrator] Starting docked flow" >&2
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        echo "[orchestrator] ERROR: SPLITSCREEN_FIFO is not set" >&2
        return 1
    fi

    # ── Write state: docked mode
    _set_mode "docked"

    # ── Listen for eligible controllers already present at startup
    # If controllers are already plugged in when flow starts, they'll
    # be picked up by the controller_monitor's initial scan → CONTROLLER_ADD.
    # ── Controller isolation note ──────────────────────────────────────
    # feat/controlify-isolation: In docked mode, the Deck's built-in
    # controller should be MASKED in ALL sandboxes via --bind /dev/null
    # (it maps to a known event node identified by
    # _identify_internal_virtual_index()). External controllers are assigned
    # one-per-slot. The masking logic in _build_bwrap_command needs to
    # know about the built-in's event node to exclude it.
    # ────────────────────────────────────────────────────────────────────

    # ── Start controller monitor (docked mode — ALL eligible controllers)
    if type start_controller_monitor >/dev/null 2>&1; then
        start_controller_monitor docked &
        _CONTROLLER_MONITOR_PID=$!
        echo "[orchestrator] Controller monitor PID: $_CONTROLLER_MONITOR_PID" >&2
    fi

    # ── Start dock detection (watch for docked→handheld transitions)
    if type watch_display_mode >/dev/null 2>&1; then
        watch_display_mode &
        _DOCK_MONITOR_PID=$!
        echo "[orchestrator] Dock monitor PID: $_DOCK_MONITOR_PID" >&2
    fi

    # ── Start watchdog (monitor process aliveness for each slot)
    if type start_watchdog >/dev/null 2>&1; then
        start_watchdog &
        _WATCHDOG_PID=$!
        echo "[orchestrator] Watchdog PID: $_WATCHDOG_PID" >&2
    fi

    # ── Event loop
    while true; do
        local msg
        if msg=$(_read_fifo_msg 5); then
            echo "[orchestrator] FIFO message: $msg" >&2
            _handle_msg "$msg" || {
                local exit_code=$?
                echo "[orchestrator] _handle_msg returned $exit_code — switching flow" >&2
                # If 1, DISPLAY_MODE_CHANGE handheld → re-enter handheld_flow
                if (( exit_code == 1 )); then
                    return 1
                fi
                # Otherwise clean exit
                break
            }
        fi

        # Check if we should settle (no active slots + timeout → exit)
        local active
        active=$(get_active_slots)
        if [[ -z "$active" ]]; then
            echo "[orchestrator] No active slots — idle" >&2
            # The loop keeps waiting; if no ADD/DISPLAY arrives within
            # a reasonable window and nothing is running, the docked
            # session naturally ends when the user quits via Steam.
            # TODO: add a SESSION_END message type for clean exit
        fi
    done

    cleanup
}

# =============================================================================
# main — Entry point: detect mode and run the correct flow
# =============================================================================
main() {
    echo "[orchestrator] main() starting — PID=$$" >&2

    # ── Ensure FIFO exists
    local fifo="${SPLITSCREEN_FIFO:-}"
    if [[ -z "$fifo" ]]; then
        fifo="/tmp/minecraft-splitscreen.fifo"
        export SPLITSCREEN_FIFO="$fifo"
    fi
    if [[ ! -p "$fifo" ]]; then
        mkfifo "$fifo" 2>/dev/null || true
    fi

    # ── Source all dependent modules
    # The file sourcing this is expected to have already sourced:
    #   dock_detection.sh, controller_monitor.sh, instance_lifecycle.sh,
    #   window_manager.sh, watchdog.sh

    # ── Detect mode
    local display_mode
    if type get_display_mode >/dev/null 2>&1; then
        display_mode=$(get_display_mode)
    elif [[ -n "${SPLITSCREEN_MODE:-}" ]]; then
        display_mode="$SPLITSCREEN_MODE"
    else
        # Default: check if external display is connected via DRM sysfs
        if is_docked 2>/dev/null; then
            display_mode="docked"
        else
            display_mode="handheld"
        fi
    fi

    echo "[orchestrator] Display mode: $display_mode" >&2
    _set_mode "$display_mode"

    # ── Run the appropriate flow
    case "$display_mode" in
        handheld)
            handheld_flow
            ;;
        docked)
            docked_flow || {
                local rc=$?
                if (( rc == 1 )); then
                    echo "[orchestrator] docked_flow requested re-entry as handheld" >&2
                    handheld_flow
                fi
            }
            ;;
        *)
            echo "[orchestrator] Unknown display mode: $display_mode — defaulting to docked" >&2
            docked_flow
            ;;
    esac

    echo "[orchestrator] main() exiting" >&2
}

# =============================================================================
# cleanup — Teardown everything and kill background processes
# =============================================================================
cleanup() {
    echo "[orchestrator] cleanup() starting" >&2

    # ── Kill watchdog
    if [[ -n "$_WATCHDOG_PID" ]] && kill -0 "$_WATCHDOG_PID" 2>/dev/null; then
        kill -TERM "$_WATCHDOG_PID" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$_WATCHDOG_PID" 2>/dev/null || true
        echo "[orchestrator] Watchdog PID $_WATCHDOG_PID killed" >&2
    fi

    # ── Kill controller monitor
    if [[ -n "$_CONTROLLER_MONITOR_PID" ]] && kill -0 "$_CONTROLLER_MONITOR_PID" 2>/dev/null; then
        kill -TERM "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
        kill -KILL "$_CONTROLLER_MONITOR_PID" 2>/dev/null || true
        echo "[orchestrator] Controller monitor PID $_CONTROLLER_MONITOR_PID killed" >&2
    fi

    # ── Kill dock monitor
    if [[ -n "$_DOCK_MONITOR_PID" ]] && kill -0 "$_DOCK_MONITOR_PID" 2>/dev/null; then
        kill -TERM "$_DOCK_MONITOR_PID" 2>/dev/null || true
        kill -KILL "$_DOCK_MONITOR_PID" 2>/dev/null || true
        echo "[orchestrator] Dock monitor PID $_DOCK_MONITOR_PID killed" >&2
    fi

    # ── Tear down all instances
    if type teardown_all_instances >/dev/null 2>&1; then
        teardown_all_instances 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
    fi

    # ── Restore panels
    if type restorePanels >/dev/null 2>&1; then
        restorePanels 2>&1 | sed 's/^/[orchestrator] /' >&2 || true
    fi

    echo "[orchestrator] cleanup() complete" >&2
}

# ── Guard: only define functions when sourced, run main() when executed directly
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    main "$@"
fi
