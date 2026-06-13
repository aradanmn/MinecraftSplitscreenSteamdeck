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

# _ensure_state_file: Create the state file with default structure if it doesn't exist.
_ensure_state_file() {
    local state_file
    state_file=$(_get_state_file)

    if [[ ! -f "$state_file" ]]; then
        local dir
        dir=$(dirname "$state_file")
        mkdir -p "$dir"

        # Initialize with all 4 slots inactive
        jq -n '{
            mode: "handheld",
            slots: {
                "1": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null},
                "2": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null},
                "3": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null},
                "4": {active: false, pid: null, event_node: null, js_node: null, bwrap_pid: null}
            }
        }' > "$state_file"
        echo "[instance_lifecycle] Initialized state file: $state_file" >&2
    fi
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

# _build_bwrap_command: Construct the bwrap command array for a slot.
# $1 = slot, $2 = event_node, $3 = js_node
# Output: the full command string (for eval or background execution)
_build_bwrap_command() {
    local slot="$1"
    local event_node="$2"
    local js_node="$3"
    local launcher_exec
    launcher_exec=$(_get_launcher_exec)

    # Build the command as a single string for background execution
    # Note: -Dorg.lwjgl.opengl.Window.title is a JVM argument.
    # PolyMC's AppImage supports --jvm-args for passing JVM flags.
    cat <<CMDEOF
bwrap \
  --dev-bind / / \
  --dev /dev \
  --dev-bind /dev/fuse /dev/fuse \
  --dev-bind /tmp/.X11-unix /tmp/.X11-unix \
  --dev-bind /tmp /tmp \
  --dev-bind /home /home \
  --dev-bind /run /run \
  --dev-bind "${event_node}" "${event_node}" \
  --dev-bind "${js_node}" "${js_node}" \
  -- \
  env \
    SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT="0x28DE/0x11FF" \
    SDL_JOYSTICK_DEVICE="${js_node}" \
    SDL_JOYSTICK_HIDAPI=0 \
    SDL_LINUX_JOYSTICK_CLASSIC=1 \
    SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD=0 \
  "${launcher_exec}" \
    -l "latestUpdate-${slot}" \
    -a "P${slot}"
CMDEOF
}

# _poll_for_java: Poll for the Java process PID.
# $1 = slot
# Returns PID on stdout, empty string if not found within timeout.
_poll_for_java() {
    local slot="$1"
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    local search_pattern="instances/latestUpdate-${slot}/natives"

    local max_iterations
    max_iterations=$(bc <<< "scale=0; ${INSTANCE_LIFECYCLE_POLL_TIMEOUT_S} / ${INSTANCE_LIFECYCLE_POLL_INTERVAL_S}" 2>/dev/null || echo "120")

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
_poll_for_window() {
    local slot="$1"

    local max_iterations
    max_iterations=$(bc <<< "scale=0; ${INSTANCE_LIFECYCLE_WINDOW_WAIT_TIMEOUT_S} / ${INSTANCE_LIFECYCLE_POLL_INTERVAL_S}" 2>/dev/null || echo "60")

    local _i
    for (( _i = 0; _i < max_iterations; _i++ )); do
        local wid
        wid=$(xdotool search --name "SplitscreenP${slot}" 2>/dev/null || true)
        if [[ -n "$wid" ]]; then
            echo "$wid"
            return 0
        fi
        sleep "$INSTANCE_LIFECYCLE_POLL_INTERVAL_S"
    done

    echo "[instance_lifecycle] WARNING: Window for slot $slot not found within ${INSTANCE_LIFECYCLE_WINDOW_WAIT_TIMEOUT_S}s" >&2
    echo ""
    return 1
}

# --- State file management ---

# Read the current state file. Returns "null" on stdout if file doesn't exist.
read_state() {
    local state_file
    state_file=$(_get_state_file)

    _ensure_state_file

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

    _ensure_state_file

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

# --- Public API ---

# Spawn a Minecraft instance in the given slot.
# $1 = slot (1-4)
# $2 = event_node (e.g. /dev/input/event4)
# $3 = js_node (e.g. /dev/input/js1)
spawn_instance() {
    local slot="${1:-}"
    local event_node="${2:-}"
    local js_node="${3:-}"

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

    # Check if slot is already active
    if slot_is_active "$slot"; then
        echo "[spawn_instance] ERROR: slot $slot is already active" >&2
        return 2
    fi

    echo "[spawn_instance] Launching instance for slot $slot ($event_node, $js_node)" >&2

    # 1. Write splitscreen.properties — need active slots for grid determination
    local active_slots
    active_slots=$(get_active_slots)
    # Include this slot in the active set for grid computation
    local new_active="${active_slots} ${slot}"
    new_active=$(echo "$new_active" | tr -s ' ' | sed 's/^ //;s/ $//')
    _write_splitscreen_properties "$slot" "$new_active"

    # 2. Clear selected_controllers.json
    local launcher_dir
    launcher_dir=$(_get_launcher_dir)
    rm -f "${launcher_dir}/instances/latestUpdate-${slot}/.minecraft/config/controllable/selected_controllers.json"

    # 3. Build the bwrap command
    local bwrap_command
    bwrap_command=$(_build_bwrap_command "$slot" "$event_node" "$js_node")

    # 4. Mark slot as active in state file (preliminary, bwrap_pid filled after launch)
    update_slot_state "$slot" "{\"active\": true, \"event_node\": \"${event_node}\", \"js_node\": \"${js_node}\", \"pid\": null, \"bwrap_pid\": null}"

    # 5. Spawn the instance
    eval "$bwrap_command" &
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

    # 7. Wait for window to appear
    _poll_for_window "$slot" >/dev/null || true

    # 8. Apply layout with all currently active slots
    local updated_active
    updated_active=$(get_active_slots)
    apply_layout "$updated_active" "" ""
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

    # 1. Send SIGTERM to bwrap_pid
    if [[ -n "$bwrap_pid" ]]; then
        kill "$bwrap_pid" 2>/dev/null || true
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

    # 3. SIGKILL if still alive
    if [[ -n "$bwrap_pid" ]] && kill -0 "$bwrap_pid" 2>/dev/null; then
        kill -9 "$bwrap_pid" 2>/dev/null || true
    fi
    if [[ -n "$java_pid" ]] && kill -0 "$java_pid" 2>/dev/null; then
        kill -9 "$java_pid" 2>/dev/null || true
    fi

    # 4. Kill placeholder window for this slot
    _kill_placeholder "$slot" 2>/dev/null || true

    # 5. Update state file: mark slot inactive
    update_slot_state "$slot" "{\"active\": false, \"pid\": null, \"bwrap_pid\": null, \"event_node\": null, \"js_node\": null}"

    # 6. Re-apply layout with remaining active slots
    local remaining
    remaining=$(get_active_slots)
    apply_layout "$remaining" "" ""
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
