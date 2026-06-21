#!/bin/bash
set -euo pipefail

# =============================================================================
# INSTANCE LIFECYCLE MODULE
# =============================================================================
# Spawns and terminates individual Minecraft instances inside bwrap sandboxes.
# Manages the shared JSON state file (atomic writes via jq + tmp + mv).
# Coordinates with the window manager for layout application.
#
# Dependencies (sourced at the top of the orchestrator):
#   dock_detection.sh, controller_monitor.sh, window_manager.sh
#
# Public API:
#   spawn_instance(slot, event_node, js_node)
#   teardown_instance(slot)
#   teardown_all_instances()
#   slot_is_active(slot)          — exit 0 if active, 1 otherwise
#
# State file:
#   read_state()                  — stdout: JSON or "null"
#   update_slot_state(slot, jq_expr)
#   get_active_slots()            — stdout: "1 3" (space-separated, ascending)
#   get_bwrap_pid(slot)           — stdout: PID or empty
#   get_java_pid(slot)            — stdout: PID or empty
#   get_window_id(slot)           — stdout: X11 WID or empty
#
# Environment overrides (for testing):
#   BWRAP_CMD                     — override bwrap path
#   LAUNCHER_EXEC                 — override PolyMC executable path
#   SPLITSCREEN_STATE             — override state file path
#   INSTANCE_LIFECYCLE_LAUNCHER_DIR — override ~/.local/share/PolyMC base
# =============================================================================

# --- Module-level constants ---
readonly INSTANCE_LIFECYCLE_MAX_PLAYERS=4
readonly INSTANCE_LIFECYCLE_POLL_INTERVAL_S=0.5
readonly INSTANCE_LIFECYCLE_POLL_TIMEOUT_S=60
readonly INSTANCE_LIFECYCLE_WINDOW_WAIT_TIMEOUT_S=30
readonly INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S=10
readonly INSTANCE_LIFECYCLE_DEFAULT_LAUNCHER_DIR="$HOME/.local/share/PolyMC"
readonly INSTANCE_LIFECYCLE_DEFAULT_STATE_FILE="$HOME/.local/share/PolyMC/splitscreen_state.json"

# --- Internal functions ---

# _get_launcher_dir: Return the PolyMC base directory.
_get_launcher_dir() {
    echo "${INSTANCE_LIFECYCLE_LAUNCHER_DIR:-$INSTANCE_LIFECYCLE_DEFAULT_LAUNCHER_DIR}"
}

# _get_state_file: Return the state file path.
_get_state_file() {
    echo "${SPLITSCREEN_STATE:-$INSTANCE_LIFECYCLE_DEFAULT_STATE_FILE}"
}

# _get_bwrap_cmd: Return the bwrap command path.
_get_bwrap_cmd() {
    echo "${BWRAP_CMD:-bwrap}"
}

# _get_launcher_exec: Return the PolyMC executable path.
_get_launcher_exec() {
    echo "${LAUNCHER_EXEC:-$(_get_launcher_dir)/PolyMC.AppImage}"
}

# _ensure_state_file: Reset the state file to default (all slots inactive).
# Called on every startup to guarantee a known clean state.
_ensure_state_file() {
    local state_file
    state_file=$(_get_state_file)

    local dir
    dir=$(dirname "$state_file")
    mkdir -p "$dir"

    # Always reset — stale state from a previous crashed session poisons the next.
    # wid field holds the X11 window ID (hex integer) so apply_layout can locate
    # the Minecraft window without relying on xdotool name-search (which fails in
    # gamescope's XWayland where xdotool set_window --name doesn't persist).
    jq -n '{
        mode: "handheld",
        slots: {
            "1": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "2": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "3": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null},
            "4": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null, wid: null}
        }
    }' > "$state_file"
    echo "[instance_lifecycle] Reset state file: $state_file" >&2
}

# _atomic_write: Write JSON content atomically to a file.
# $1 = file path, $2 = JSON content
_atomic_write() {
    local target="$1"
    local content="$2"
    local tmp="${target}.tmp.$$"

    echo "$content" > "$tmp"
    mv "$tmp" "$target"
}

# _write_splitscreen_properties: Write splitscreen.properties for a given slot.
# $1 = slot (1-4)
# $2 = space-separated active slots (used to determine grid mode)
_write_splitscreen_properties() {
    local slot="$1"
    local active_slots="${2:-}"

    local grid_mode
    grid_mode=$(compute_grid_mode "$active_slots")

    local mode_value
    case "$grid_mode" in
        full)
            mode_value="FULLSCREEN"
            ;;
        half)
            case "$slot" in
                1) mode_value="TOP" ;;
                2) mode_value="BOTTOM" ;;
                *) mode_value="FULLSCREEN" ;; # fallback
            esac
            ;;
        quad)
            case "$slot" in
                1) mode_value="TOP_LEFT" ;;
                2) mode_value="TOP_RIGHT" ;;
                3) mode_value="BOTTOM_LEFT" ;;
                4) mode_value="BOTTOM_RIGHT" ;;
                *) mode_value="FULLSCREEN" ;; # fallback
            esac
            ;;
        *)
            mode_value="FULLSCREEN"
            ;;
    esac

    local launcher_dir
    launcher_dir=$(_get_launcher_dir)

    local config_dir="${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config"
    local prop_file="${config_dir}/splitscreen.properties"

    mkdir -p "$config_dir"

    cat > "$prop_file" <<PROPEOF
gap=1
mode=${mode_value}
PROPEOF

    echo "[instance_lifecycle] Wrote splitscreen.properties for slot $slot: mode=$mode_value (grid=$grid_mode)" >&2
}

# _build_bwrap_command: Construct a bwrap command string with printf '%q' quoting.
# $1 = slot, $2 = event_node, $3 = js_node
# $4+ = pairs of (mask_event, mask_js) for other controllers to mask
# Output: a single command string (printf '%q' quoted) ready for eval.
_build_bwrap_command() {
    local slot="$1"
    local event_node="$2"
    local js_node="$3"
    shift 3
    local launcher_exec
    launcher_exec=$(_get_launcher_exec)

    local -a cmd=(
        $(_get_bwrap_cmd)
        --dev-bind / /
        --dev /dev
        --dev-bind /dev/fuse /dev/fuse
        --dev-bind /tmp /tmp
        --dev-bind /tmp/.X11-unix /tmp/.X11-unix
        --dev-bind /home /home
        --dev-bind /run /run
        --dev-bind /dev/dri /dev/dri
        --dev-bind "${event_node}" "${event_node}"
    )

    # js_node is optional — char devices fail -f; use -e which matches any file type
    if [[ -e "$js_node" ]]; then
        cmd+=(--dev-bind "${js_node}" "${js_node}")
        # Set SDL_JOYSTICK_DEVICE to the assigned joystick only
        cmd+=(--setenv "SDL_JOYSTICK_DEVICE" "${js_node}")
    fi

    # Mask other controllers: use if-statements, not &&, to avoid set -e
    # interpreting a "file not found" as a fatal error
    while [[ $# -ge 2 ]]; do
        local mask_event="$1" mask_js="$2"
        shift 2
        if [[ -e "$mask_event" ]]; then cmd+=(--bind /dev/null "${mask_event}"); fi
        if [[ -e "$mask_js"    ]]; then cmd+=(--bind /dev/null "${mask_js}"); fi
    done

    # SDL env vars — explicitly override Steam's inherited environment:
    #   SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1:
    #     Lets SDL3 see 28de:11ff Steam virtual Xbox pads (the only device in this sandbox).
    #     Steam sets this=1 by default; we set it explicitly to ensure it's not overridden.
    #   SDL_GAMECONTROLLER_IGNORE_DEVICES= (empty):
    #     Clears Steam's DS4 VID/PID exclusion list, so SDL can use evdev directly
    #     If the Steam IPC socket isn't available. Not strictly needed for 28de:11ff
    #     pads, but harmless and defensive against future Steam changes.
    #   SDL_JOYSTICK_HIDAPI=0:
    #     Disables HIDAPI backend (no /dev/hidraw* nodes in this sandbox).
    #     SDL3 falls back to pure evdev where our bound event/js nodes live.
    #   SDL_LINUX_JOYSTICK_CLASSIC=1:
    #     Forces classic joystick driver path, ensuring SDL_JOYSTICK_DEVICE
    #     pinning is honoured on Linux. Required for compatibility with the
    #     older Controllable mod's bundled SDL and some gamescope builds.
    # AppImage / Qt / audio env — must match the known-working launchSlot config.
    #   APPIMAGE_EXTRACT_AND_RUN=1: the AppImage cannot FUSE-mount inside the
    #     sandbox (no fusermount on PATH → "Cannot mount AppImage"); extract-and-run
    #     sidesteps FUSE entirely. THIS is what was killing every spawn_instance.
    #   QT_QPA_PLATFORM=xcb: force PolyMC's Qt GUI onto X11 — the nested KDE session
    #     exports QT_QPA_PLATFORM=wayland, which PolyMC would otherwise inherit.
    #   PULSE_SERVER: absolute path to the host socket so audio works regardless of
    #     XDG_RUNTIME_DIR (the socket is inside the sandbox via --dev-bind / /).
    cmd+=(
        --
        env
        APPIMAGE_EXTRACT_AND_RUN=1
        QT_QPA_PLATFORM=xcb
        "PULSE_SERVER=unix:/run/user/$(id -u)/pulse/native"
        SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=1
        SDL_GAMECONTROLLER_IGNORE_DEVICES=
        SDL_JOYSTICK_HIDAPI=0
        SDL_LINUX_JOYSTICK_CLASSIC=1
        "${launcher_exec}"
        -l "latestUpdate-${slot}"
        -a "P${slot}"
    )

    # Output the command as a safely-quoted single string
    printf '%q ' "${cmd[@]}"
}

# _poll_for_java: Poll for the Java process PID.
# $1 = slot
# Returns PID on stdout, empty string if not found within timeout.
_poll_for_java() {
    local slot="$1"
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    local search_pattern="instances/latestUpdate-${slot}/natives"

    local max_iterations=120   # POLL_TIMEOUT_S(60) / POLL_INTERVAL_S(0.5)

    local _i
    for (( _i = 0; _i < max_iterations; _i++ )); do
        local found_pid
        found_pid=$(pgrep -af "$search_pattern" 2>/dev/null | head -1 | awk '{print $1}' || true)
        if [[ -n "$found_pid" ]]; then
            echo "$found_pid"
            return 0
        fi
        sleep "$INSTANCE_LIFECYCLE_POLL_INTERVAL_S"
    done

    echo "[instance_lifecycle] WARNING: Java process for slot $slot not found within ${INSTANCE_LIFECYCLE_POLL_TIMEOUT_S}s" >&2
    echo ""
    return 1
}

# _poll_for_window: Wait for the Minecraft window to appear.
# $1 = slot
# Returns window ID on stdout, empty string if timeout.
# Strategy (via dex — the single X11 layer):
#   1. dex_search --name "SplitscreenP<slot>" — works only with LWJGL 2
#   2. dex_search --pid <java_pid> (matches _NET_WM_PID) — LWJGL 3 (MC 1.18+)
#      On match: rename WM_NAME (dex_set_name) so apply_layout / _get_wid_from_state
#      can find it by name on future calls. Positioning is apply_layout's job.
_poll_for_window() {
    local slot="$1"

    local max_iterations=240    # 120s at 0.5s interval (Minecraft takes 60-90s to load)

    local _i
    for (( _i = 0; _i < max_iterations; _i++ )); do
        # Strategy 1: title-based (works if the LWJGL2 title property was honoured)
        local wid
        wid=$(dex_search --name "SplitscreenP${slot}" 2>/dev/null | head -1 || true)
        if [[ -n "$wid" ]]; then
            echo "$wid"
            return 0
        fi

        # Strategy 2: PID-based after a short warm-up (LWJGL3 ignores the title
        # property; match the JVM's _NET_WM_PID instead).
        if (( _i > 10 )); then
            local java_pid
            java_pid=$(get_java_pid "$slot")
            if [[ -n "$java_pid" ]]; then
                # tail -1 picks the most-recently-opened window from this PID tree
                # (avoids grabbing PrismLauncher's own launch dialog if still open)
                wid=$(dex_search --pid "$java_pid" 2>/dev/null | tail -1 || true)
                if [[ -n "$wid" ]]; then
                    echo "[instance_lifecycle] Found window by PID $java_pid for slot $slot: wid=$wid" >&2
                    # Rename WM_NAME so apply_layout / _get_wid_from_state can find
                    # it by name on subsequent calls.
                    dex_set_name "$wid" "SplitscreenP${slot}" 2>/dev/null || true

                    # NOTE: window POSITIONING (override_redirect + move/resize) is
                    # intentionally NOT done here. apply_layout() positions every
                    # active slot via dex right after spawn_instance records this WID.
                    # This function previously carried TWO inline-ctypes OR-cycle
                    # copies (gamescope + desktop, both with the old pointer-
                    # truncation + 1<<3 valuemask bugs) plus an xdotool fallback;
                    # all removed in favour of the single verified dex X11 layer.
                    # The STEAM_GAME/STEAM_OVERLAY plane setup also went away — it
                    # targets bare gamescope, not the nested-KWin approach we use.
                    echo "$wid"
                    return 0
                fi
            fi
        fi

        sleep "$INSTANCE_LIFECYCLE_POLL_INTERVAL_S"
    done

    echo "[instance_lifecycle] WARNING: Window for slot $slot not found within 120s" >&2
    echo ""
    return 1
}

# --- State file management ---

# Read the current state file. Returns "null" on stdout if file doesn't exist.
read_state() {
    local state_file
    state_file=$(_get_state_file)

    jq -c '.' "$state_file" 2>/dev/null || echo "null"
}

# Update a single slot's fields by merging the provided JSON object.
# $1 = slot (1-4), $2 = JSON object to merge into the slot's data
# The provided object is recursively merged with the existing slot data via jq's * operator.
update_slot_state() {
    local slot="$1"
    local merge_json="$2"
    local state_file
    state_file=$(_get_state_file)

    # Only initialize if missing — main() calls _ensure_state_file at startup
    if [[ ! -f "$state_file" ]]; then
        _ensure_state_file
    fi

    local updated
    updated=$(jq --arg slot "$slot" --argjson merge "$merge_json" \
        '.slots[$slot] = ((.slots[$slot] // {}) * $merge)' \
        "$state_file" 2>/dev/null) || {
        echo "[instance_lifecycle] ERROR: jq update failed for slot $slot" >&2
        return 1
    }

    _atomic_write "$state_file" "$updated"
}

# Return active slot numbers as a space-separated string (ascending order).
get_active_slots() {
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r '[.slots | to_entries[] | select(.value.active == true) | .key | tonumber] | sort | join(" ")' <<< "$state" 2>/dev/null
}

# Return the bwrap PID for a slot.
get_bwrap_pid() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r ".slots[\"$slot\"].bwrap_pid // empty" <<< "$state" 2>/dev/null
}

# Return the Java PID for a slot.
get_java_pid() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r ".slots[\"$slot\"].pid // empty" <<< "$state" 2>/dev/null
}

# Return the X11 window ID (WID) for a slot, or empty if not known.
# Used by apply_layout to find the Minecraft window without xdotool name-search.
get_window_id() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        echo ""
        return 0
    fi

    jq -r ".slots[\"$slot\"].wid // empty" <<< "$state" 2>/dev/null
}

# --- Public API ---

# Spawn a Minecraft instance in the given slot.
# $1 = slot (1-4)
# $2 = event_node (e.g. /dev/input/event4)
# $3 = js_node (e.g. /dev/input/js1)
spawn_instance() {
    local slot="${1:-}"
    local event_node="${2:-}"
    local js_node="${3:-}"
    # Args 4+: pairs of (event_node, js_node) for other controllers to mask in bwrap
    local -a mask_controllers=()
    if [[ $# -gt 3 ]]; then
        mask_controllers=("${@:4}")
    fi

    if [[ -z "$slot" || -z "$event_node" || -z "$js_node" ]]; then
        echo "[spawn_instance] ERROR: slot, event_node, and js_node are required" >&2
        return 1
    fi

    local bwrap_cmd
    bwrap_cmd=$(_get_bwrap_cmd)

    # Check bwrap availability
    if ! command -v "$bwrap_cmd" >/dev/null 2>&1; then
        echo "[spawn_instance] ERROR: $bwrap_cmd (bubblewrap) is required but not found. Cannot sandbox instance." >&2
        return 1
    fi

    # Check if slot is already active with a running instance
    if slot_is_active "$slot"; then
        local existing_bwrap
        existing_bwrap=$(get_bwrap_pid "$slot")
        if [[ -n "$existing_bwrap" ]]; then
            echo "[spawn_instance] ERROR: slot $slot is already active (bwrap_pid=$existing_bwrap)" >&2
            return 2
        fi
        # Slot was pre-reserved (active but no bwrap_pid) — continue
        echo "[spawn_instance] Slot $slot pre-reserved, proceeding with launch" >&2
    fi

    echo "[spawn_instance] Launching instance for slot $slot ($event_node, $js_node)" >&2

    # ── Mock mode ─────────────────────────────────────────────────────────────
    # When SPLITSCREEN_MOCK_SPAWN=1, replace bwrap+PolyMC with a sleep stub.
    # Exercises the orchestrator's FIFO dispatch and state machine without any
    # hardware (no controllers, no real game).  teardown_instance works unchanged
    # because it just kills the stub PID.
    if [[ "${SPLITSCREEN_MOCK_SPAWN:-}" == "1" ]]; then
        sleep 86400 &
        local stub_pid=$!
        update_slot_state "$slot" \
            "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": ${stub_pid}, \"bwrap_pid\": ${stub_pid}, \"wid\": null}"
        echo "[spawn_instance] MOCK: slot $slot active (stub_pid=$stub_pid)" >&2
        return 0
    fi

    # 1. Write splitscreen.properties — need active slots for grid determination
    local active_slots
    active_slots=$(get_active_slots)
    # Include this slot in the active set for grid computation
    local new_active="${active_slots} ${slot}"
    new_active=$(echo "$new_active" | tr -s ' ' | sed 's/^ //;s/ $//')
    _write_splitscreen_properties "$slot" "$new_active"
    # Also update all already-active slots so they see the correct layout
    # (they were written with old player count before this slot joined)
    local _other_slot
    for _other_slot in $active_slots; do
        _write_splitscreen_properties "$_other_slot" "$new_active"
    done

    # 2. Clear selected_controllers.json
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    rm -f "${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config/controllable/selected_controllers.json"

    # 2.3 Set out_of_focus_input=true so unfocused instances respond to their controller
    local controlify_cfg="${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config/controlify.json"
    if [[ -f "$controlify_cfg" ]] && command -v jq >/dev/null 2>&1; then
        local updated_cfg
        updated_cfg=$(jq '.global.out_of_focus_input = true' "$controlify_cfg" 2>/dev/null)
        if [[ -n "$updated_cfg" ]]; then
            echo "$updated_cfg" > "$controlify_cfg"
            echo "[spawn_instance] Set out_of_focus_input=true for slot $slot" >&2
        fi
    fi

    # 2.5 Set window title via instance.cfg JvmArgs
    local cfg_path="${launcher_dir}/instances/latestUpdate-${slot}/instance.cfg"
    if [[ -f "$cfg_path" ]]; then
        setInstanceCfgValue "$cfg_path" "OverrideJavaArgs" "true"
        setInstanceCfgValue "$cfg_path" "JvmArgs" "-Dorg.lwjgl.opengl.Window.title=SplitscreenP${slot}"
        echo "[spawn_instance] Set window title SplitscreenP${slot} via instance.cfg" >&2
    fi

    # 3. Build the bwrap command string
    local bwrap_command
    if [[ ${#mask_controllers[@]} -gt 0 ]]; then
        bwrap_command=$(_build_bwrap_command "$slot" "$event_node" "$js_node" "${mask_controllers[@]}")
    else
        bwrap_command=$(_build_bwrap_command "$slot" "$event_node" "$js_node")
    fi

    # 4. Mark slot as active in state file (preliminary, bwrap_pid filled after launch)
    update_slot_state "$slot" "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": null, \"bwrap_pid\": null}"

    # 5. Spawn the instance in its OWN process group via setsid.
    #    Previously `eval "$bwrap_command" &; bwrap_pid=$!` captured the PID of a
    #    transient subshell wrapper, NOT the real bwrap process (off by ~2). That
    #    made the watchdog fire spurious SLOT_DIED (it saw the wrapper exit) and
    #    made teardown SIGTERM the wrong PID, leaking the whole bwrap→PolyMC→java
    #    tree. setsid makes bwrap the session/group leader so $! is the real
    #    group-leader PID; teardown signals the negative PID to kill the group.
    setsid bash -c "$bwrap_command" </dev/null &
    local bwrap_pid=$!

    update_slot_state "$slot" "{\"bwrap_pid\": ${bwrap_pid}}"
    echo "[spawn_instance] bwrap PID: $bwrap_pid" >&2

    # 6. Poll for Java process
    local java_pid
    java_pid=$(_poll_for_java "$slot" || true)
    if [[ -n "$java_pid" ]]; then
        update_slot_state "$slot" "{\"pid\": ${java_pid}}"
        echo "[spawn_instance] Java PID: $java_pid" >&2
    fi

    # 7. Wait for window to appear and store its WID in state
    local window_id
    window_id=$(_poll_for_window "$slot" || true)
    if [[ -n "$window_id" ]]; then
        update_slot_state "$slot" "{\"wid\": ${window_id}}"
        echo "[spawn_instance] Stored WID $window_id for slot $slot" >&2
    fi

    # 8. Apply layout with all currently active slots
    local updated_active
    updated_active=$(get_active_slots)

    # In gamescope mode, use the gamescope windowing system
    if [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]] || [[ -n "${GAMESCOPE_REFRESH_RATE:-}" ]]; then
        if command -v gamescope_windowing_apply_layout >/dev/null 2>&1 || type gamescope_windowing_apply_layout >/dev/null 2>&1; then
            gamescope_windowing_apply_layout "$updated_active" "" ""
        else
            # Fallback: use standard xdotool layout
            sync_apply_layout "$updated_active" "" ""
        fi
    else
        # Desktop mode: use standard window manager layout
        sync_apply_layout "$updated_active" "" ""
    fi
}

# Tear down the instance in the given slot.
# $1 = slot
teardown_instance() {
    local slot="$1"

    if ! slot_is_active "$slot"; then
        echo "[teardown_instance] Slot $slot is not active, nothing to tear down" >&2
        return 0
    fi

    echo "[teardown_instance] Tearing down slot $slot" >&2

    local bwrap_pid
    bwrap_pid=$(get_bwrap_pid "$slot")
    local java_pid
    java_pid=$(get_java_pid "$slot")

    # bwrap_pid is the process-group leader (see spawn_instance / setsid), so the
    # whole bwrap→PolyMC→java tree shares PGID == bwrap_pid. Signalling the
    # NEGATIVE pid hits the entire group, which is the only reliable way to reap
    # the tree (PolyMC's AppImage extract-and-run forks intermediate processes
    # that a single-PID kill misses).
    # 1. Send SIGTERM to the whole group (fall back to single PID if group is gone)
    if [[ -n "$bwrap_pid" ]]; then
        kill -TERM "-${bwrap_pid}" 2>/dev/null || kill -TERM "$bwrap_pid" 2>/dev/null || true
    fi

    # 2. Wait up to TEARDOWN_GRACE_S for processes to exit
    local _i
    for (( _i = 0; _i < INSTANCE_LIFECYCLE_TEARDOWN_GRACE_S; _i++ )); do
        local still_alive=0
        if [[ -n "$bwrap_pid" ]] && kill -0 "$bwrap_pid" 2>/dev/null; then
            still_alive=1
        fi
        if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
            still_alive=1
        fi
        if (( still_alive == 0 )); then
            break
        fi
        sleep 1
    done

    # 3. SIGKILL the whole group if anything is still alive, then mop up the
    #    individually-tracked PIDs as a belt-and-suspenders fallback.
    if [[ -n "$bwrap_pid" ]]; then
        if kill -0 "$bwrap_pid" 2>/dev/null || kill -0 "$java_pid" 2>/dev/null; then
            kill -KILL "-${bwrap_pid}" 2>/dev/null || kill -9 "$bwrap_pid" 2>/dev/null || true
        fi
    fi
    if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
        kill -9 "$java_pid" 2>/dev/null || true
    fi

    # 4. Kill placeholder window for this slot
    _kill_placeholder "$slot" 2>/dev/null || true

    # 5. Update state file: mark slot inactive (including WID so layout doesn't find a stale window)
    update_slot_state "$slot" "{\"active\": false, \"pid\": null, \"bwrap_pid\": null, \"event_node\": null, \"js_node\": null, \"wid\": null}"

    # 6. Re-apply layout with remaining active slots
    local remaining
    remaining=$(get_active_slots)
    if [[ "${XDG_SESSION_DESKTOP:-}" == "gamescope" ]] || [[ -n "${GAMESCOPE_REFRESH_RATE:-}" ]]; then
        if command -v gamescope_windowing_apply_layout >/dev/null 2>&1 || type gamescope_windowing_apply_layout >/dev/null 2>&1; then
            gamescope_windowing_apply_layout "$remaining" "" ""
        else
            sync_apply_layout "$remaining" "" ""
        fi
    else
        sync_apply_layout "$remaining" "" ""
    fi
}

# Tear down all active instances.
teardown_all_instances() {
    echo "[teardown_all_instances] Tearing down all instances" >&2

    local active
    active=$(get_active_slots)

    local slot
    for slot in $active; do
        teardown_instance "$slot"
    done
}

# Return 0 if the given slot has an active running instance, 1 otherwise.
# $1 = slot
slot_is_active() {
    local slot="$1"
    local state
    state=$(read_state)

    if [[ "$state" == "null" ]]; then
        return 1
    fi

    local is_active
    is_active=$(jq -r ".slots[\"$slot\"].active // false" <<< "$state" 2>/dev/null)

    if [[ "$is_active" == "true" ]]; then
        return 0
    else
        return 1
    fi
}
